#!/usr/bin/env perl
use strict;
use warnings;
use JSON::PP qw(decode_json);
use POSIX qw(strftime);

sub run {
    system { $_[0] } @_;
    die "$_[0] failed (status $?)\n" if $? != 0;
}

sub capture {
    open my $pipe, '-|', @_ or die "Cannot start $_[0]: $!\n";
    local $/;
    my $output = <$pipe> // '';
    close $pipe or die "$_[0] failed (status $?)\n";
    return $output;
}

sub parse_version {
    my ($version) = @_;
    return ($1, $2, $3, $4)
        if $version =~ /\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\+([0-9a-f]+)\z/;
    die "Invalid release version: $version\n";
}

sub read_json {
    my ($path) = @_;
    open my $file, '<', $path or die "Cannot read $path: $!\n";
    local $/;
    my $value = decode_json(<$file>);
    close $file or die "Cannot close $path: $!\n";
    return $value;
}

sub write_json {
    my ($path, $value) = @_;
    open my $file, '>', "$path.tmp" or die "Cannot write $path.tmp: $!\n";
    print {$file} JSON::PP->new->canonical->pretty->encode($value) or die "Cannot write $path: $!\n";
    close $file or die "Cannot close $path: $!\n";
    rename "$path.tmp", $path or die "Cannot replace $path: $!\n";
}

sub read_bases {
    my $bases = read_json('bases.json');
    die "Expected a nonempty base list\n" unless ref $bases eq 'ARRAY' && @$bases;
    my (%names, %suffixes);
    for my $base (@$bases) {
        die "Invalid base definition\n" unless ref $base eq 'HASH'
            && ($base->{name} // '') =~ /\A[a-z0-9][a-z0-9.-]*\z/
            && ($base->{image} // '') =~ /\A[a-z0-9][a-z0-9.:\/-]*\z/
            && defined $base->{suffix} && $base->{suffix} =~ /\A(?:-[a-z0-9][a-z0-9.-]*)?\z/;
        die "Duplicate base name\n" if $names{$base->{name}}++;
        die "Expected alias array\n" if exists $base->{aliases} && ref $base->{aliases} ne 'ARRAY';
        for my $suffix ($base->{suffix}, @{$base->{aliases} // []}) {
            die "Invalid tag suffix\n" unless defined $suffix && $suffix =~ /\A(?:-[a-z0-9][a-z0-9.-]*)?\z/;
            die "Duplicate tag suffix\n" if $suffixes{$suffix}++;
        }
    }
    return $bases;
}

sub read_versions {
    my ($path) = @_;
    my $history = read_json($path);
    die "Expected base-keyed version history\n" unless ref $history eq 'HASH';
    for my $versions (values %$history) {
        die "Expected version array\n" unless ref $versions eq 'ARRAY';
        parse_version($_) for @$versions;
    }
    return $history;
}

sub release_tags {
    my ($version, $latest, $history) = @_;
    my ($major, $minor, $patch, $hash) = parse_version($version);
    # Rebuilding an older patch must not move the minor tag backward.
    # Rebuilding the newest patch may refresh it with a new base image.
    my $newest = 1;
    for my $published (@$history) {
        my ($a, $b, $c) = parse_version($published);
        $newest = 0 if $a == $major && $b == $minor && $c > $patch;
    }
    my @tags = ("$major.$minor.$patch", "$major.$minor.$patch-$hash");
    push @tags, "$major.$minor" if $newest;
    push @tags, 'latest' if $latest;
    return @tags;
}

sub sources {
    my ($image, $directory) = @_;
    my @sources;
    for my $arch ('amd64', 'arm64') {
        my $path = "$directory/$arch.digest";
        open my $file, '<', $path or die "Missing $arch digest: $!\n";
        my $digest = do { local $/; <$file> } // '';
        close $file or die "Cannot close $path: $!\n";
        chomp $digest;
        die "Invalid $arch digest\n" unless $digest =~ /\Asha256:[0-9a-f]{64}\z/;
        push @sources, "$image\@$digest";
    }
    die "Architecture digests must differ\n" if $sources[0] eq $sources[1];
    return @sources;
}

sub registry_token {
    my ($repository) = @_;
    my $response = decode_json(capture(
        'curl', '-fsS', '--get', 'https://ghcr.io/token',
        '--data-urlencode', 'service=ghcr.io',
        '--data-urlencode', "scope=repository:$repository:pull",
    ));
    my $token = $response->{token};
    die "Missing registry token\n" unless defined $token && !ref $token && length $token;
    return $token;
}

sub dated_tag_exists {
    my ($repository, $tag, $token) = @_;
    my $status = capture(
        'curl', '-sS', '--head', '--output', '/dev/null', '--write-out', '%{http_code}',
        '--header', "Authorization: Bearer $token",
        '--header', 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json',
        "https://ghcr.io/v2/$repository/manifests/$tag",
    );
    return 1 if $status eq '200';
    return 0 if $status eq '404';
    die "Cannot check $tag: HTTP $status\n";
}

sub publish {
    my ($image, $version, $latest, $digest_dir, $history, $base) = @_;
    my $nightly = $version eq 'nightly';
    my @suffixes = ($base->{suffix}, @{$base->{aliases} // []});
    my @sources = sources($image, "$digest_dir/$base->{name}");
    my (@tags, @inspect);
    if ($nightly) {
        my $repository = $image;
        $repository =~ s{\Aghcr\.io/}{} or die "Expected a ghcr.io image\n";
        # Date each base at publication time; independent builds may span midnight.
        my $date = 'nightly-' . strftime('%Y%m%d', gmtime);
        my @dated = map { "$date$_" } @suffixes;
        my $token = registry_token($repository);
        my (@existing, @missing);
        for my $tag (@dated) {
            if (dated_tag_exists($repository, $tag, $token)) { push @existing, $tag; }
            else { push @missing, $tag; }
        }
        @tags = map { "nightly$_" } @suffixes;
        if (@existing) {
            # A newly introduced alias or a partial publish must reuse the day's
            # original index, not today's rebuilt image. A single index source
            # is copied unchanged by imagetools create.
            run('docker', 'buildx', 'imagetools', 'create',
                (map { ('-t', "$image:$_") } @missing), "$image:$existing[0]") if @missing;
        } else {
            push @tags, @missing;
        }
        @inspect = ((map { "nightly$_" } @suffixes), @dated);
    } else {
        @tags = map {
            my $tag = $_;
            map { "$tag$_" } @suffixes;
        } release_tags($version, $latest, $history->{$base->{name}} // []);
        @inspect = @tags;
    }
    run('docker', 'buildx', 'imagetools', 'create',
        (map { ('-t', "$image:$_") } @tags), @sources);
    run('docker', 'buildx', 'imagetools', 'inspect', "$image:$_") for @inspect;
}

sub main {
    my $image = $ENV{IMAGE} // die "IMAGE is required\n";
    my $version = $ENV{VERSION} // die "VERSION is required\n";
    my $name = $ENV{BASE} // die "BASE is required\n";
    my $digest_dir = $ENV{DIGEST_DIR} // die "DIGEST_DIR is required\n";
    my ($base) = grep { $_->{name} eq $name } @{read_bases()};
    die "Unknown base: $name\n" unless $base;
    my $latest = ($ENV{LATEST} // 'false') eq 'true';
    my $history = {};
    if ($version ne 'nightly') {
        # Refresh history for reruns without giving publication jobs write access.
        run('git', 'pull', '--ff-only');
        $history = read_versions('versions.json');
    }
    publish($image, $version, $latest, $digest_dir, $history, $base);
    # This receipt is uploaded only after all publication checks succeed.
    if ($version ne 'nightly') {
        my $receipt_dir = $ENV{RECEIPT_DIR} // die "RECEIPT_DIR is required\n";
        mkdir $receipt_dir unless -d $receipt_dir;
        write_json("$receipt_dir/$name.json", { base => $name, version => $version });
    }
}

main() unless caller;
1;

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

sub read_versions {
    my ($path) = @_;
    open my $file, '<', $path or die "Cannot read $path: $!\n";
    my @versions = <$file>;
    close $file or die "Cannot close $path: $!\n";
    chomp @versions;
    parse_version($_) for @versions;
    return @versions;
}

sub release_tags {
    my ($version, $latest, $history) = @_;
    my ($major, $minor, $patch, $hash) = parse_version($version);
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
    opendir my $dir, $directory or die "Cannot read $directory: $!\n";
    my @digests = sort grep { $_ ne '.' && $_ ne '..' } readdir $dir;
    closedir $dir;
    die "Expected two architecture digests in $directory\n" unless @digests == 2;
    for my $digest (@digests) {
        die "Invalid digest in $directory: $digest\n"
            unless $digest =~ /\A[0-9a-f]{64}\z/ && -f "$directory/$digest";
    }
    return map { "$image\@sha256:$_" } @digests;
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
    my ($image, $version, $latest, $digest_dir, $history) = @_;
    my $nightly = $version eq 'nightly';
    my @release_tags = $nightly ? () : release_tags($version, $latest, $history);
    my $date = strftime('%Y%m%d', gmtime);
    my $repository = $image;
    $repository =~ s{\Aghcr\.io/}{} or die "Expected a ghcr.io image\n";

    # Validate all bases and check dated tags before changing any public tags.
    my @plans;
    my $token = $nightly ? registry_token($repository) : undef;
    for my $base ('trixie', 'bookworm', 'bci16.0') {
        my $suffix = $base eq 'trixie' ? '' : "-$base";
        my @sources = sources($image, "$digest_dir/$base");
        my (@tags, @inspect);
        if ($nightly) {
            my $dated = "nightly-$date$suffix";
            @tags = ("nightly$suffix");
            if (dated_tag_exists($repository, $dated, $token)) {
                print "$dated already exists; preserving it\n";
            } else {
                push @tags, $dated;
            }
            @inspect = ("nightly$suffix", $dated);
        } else {
            @tags = map { "$_$suffix" } @release_tags;
            @inspect = @tags;
        }
        push @plans, { tags => \@tags, inspect => \@inspect, sources => \@sources };
    }
    for my $plan (@plans) {
        run('docker', 'buildx', 'imagetools', 'create',
            (map { ('-t', "$image:$_") } @{$plan->{tags}}), @{$plan->{sources}});
        run('docker', 'buildx', 'imagetools', 'inspect', "$image:$_") for @{$plan->{inspect}};
    }
}

sub record_version {
    my ($version, $history) = @_;
    return if grep { $_ eq $version } @$history;
    open my $file, '>>', 'versions.txt' or die "Cannot append versions.txt: $!\n";
    print {$file} "$version\n" or die "Cannot write versions.txt: $!\n";
    close $file or die "Cannot close versions.txt: $!\n";
    run('git', 'config', 'user.name', 'github-actions[bot]');
    run('git', 'config', 'user.email', '41898282+github-actions[bot]@users.noreply.github.com');
    run('git', 'add', 'versions.txt');
    run('git', 'commit', '-m', "Record $version");
    run('git', 'push');
}

sub main {
    my $image = $ENV{IMAGE} // die "IMAGE is required\n";
    my $version = $ENV{VERSION} // die "VERSION is required\n";
    my $digest_dir = $ENV{DIGEST_DIR} // die "DIGEST_DIR is required\n";
    my $latest = ($ENV{LATEST} // 'false') eq 'true';
    # Reruns can check out an old workflow commit. Read current publication
    # history before deciding whether a minor tag may advance.
    run('git', 'pull', '--ff-only') unless $version eq 'nightly';
    my @history = $version eq 'nightly' ? () : read_versions('versions.txt');
    publish($image, $version, $latest, $digest_dir, \@history);
    # Record only after all bases have been published and inspected.
    record_version($version, \@history) unless $version eq 'nightly';
}

main() unless caller;
1;

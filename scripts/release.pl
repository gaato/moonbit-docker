#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
require "$FindBin::Bin/publish.pl";

sub select_bases {
    my ($bases, $history, $version, $selector, $force) = @_;
    die "Unknown base: $selector\n"
        unless $selector eq 'all' || grep { $_->{name} eq $selector } @$bases;
    return [grep {
        my $base = $_;
        ($selector eq 'all' || $base->{name} eq $selector)
            && ($force || $version eq 'nightly'
                || !grep { $_ eq $version } @{$history->{$base->{name}} // []})
    } @$bases];
}

sub prepare {
    my $bases = read_bases();
    my $input = $ENV{INPUT_VERSION} // '';
    my $selector = $ENV{INPUT_BASE} || 'all';
    my ($version, $latest, $history) = ('nightly', 0, {});
    if (($ENV{CHANNEL} // 'release') ne 'nightly') {
        run('git', 'pull', '--ff-only');
        $history = read_versions('versions.json');
        my $response = decode_json(capture('curl', '-fsSL', 'https://cli.moonbitlang.com/version.json'));
        my ($compiler) = grep { $_->{name} eq 'moonc' } @{$response->{items}};
        die "Missing upstream compiler version\n" unless $compiler;
        my $upstream = $compiler->{version};
        $upstream =~ s/^v//;
        $upstream =~ s/ .*//;
        parse_version($upstream);
        $version = length $input ? $input : $upstream;
        parse_version($version);
        $latest = $version eq $upstream;
    }
    # Automatic runs retry only the current release, never a backlog. An explicit
    # version forces selected bases to rebuild even when history records success.
    my $selected = select_bases($bases, $history, $version, $selector, length $input);
    my $matrix = JSON::PP->new->canonical->encode({ include => $selected });
    my $output = $ENV{GITHUB_OUTPUT} // die "GITHUB_OUTPUT is required\n";
    open my $file, '>>', $output or die "Cannot open $output: $!\n";
    print {$file} "build=", (@$selected ? 'true' : 'false'), "\n",
        "version=$version\nlatest=", ($latest ? 'true' : 'false'), "\nmatrix=$matrix\n";
    close $file or die "Cannot close $output: $!\n";
    print "Selected bases: ", join(', ', map { $_->{name} } @$selected), "\n";
}

sub merge_receipts {
    my ($history, $directory, $version, $targets) = @_;
    parse_version($version);
    my %allowed = map { $_->{name} => 1 } @$targets;
    my @receipts;
    if (-d $directory) {
        opendir my $dir, $directory or die "Cannot open $directory: $!\n";
        for my $name (sort grep { /\.json\z/ } readdir $dir) {
            my $receipt = read_json("$directory/$name");
            die "Invalid publication receipt: $name\n" unless ref $receipt eq 'HASH'
                && $allowed{$receipt->{base} // ''}
                && ($receipt->{version} // '') eq $version
                && $name eq "$receipt->{base}.json";
            push @receipts, $receipt;
        }
        closedir $dir;
    }
    # Validate every receipt before touching the history.
    my $changed = 0;
    for my $receipt (@receipts) {
        my $versions = $history->{$receipt->{base}} //= [];
        next if grep { $_ eq $version } @$versions;
        push @$versions, $version;
        $changed = 1;
    }
    return $changed;
}

sub record {
    my $version = $ENV{VERSION} // die "VERSION is required\n";
    my $directory = $ENV{RECEIPT_DIR} // die "RECEIPT_DIR is required\n";
    my $matrix = decode_json($ENV{TARGETS} // die "TARGETS is required\n");
    my %known = map { $_->{name} => 1 } @{read_bases()};
    die "Invalid target matrix\n" unless ref $matrix->{include} eq 'ARRAY';
    for my $target (@{$matrix->{include}}) {
        die "Unknown receipt target\n" unless $known{$target->{name}};
    }
    run('git', 'pull', '--ff-only');
    my $history = read_versions('versions.json');
    unless (merge_receipts($history, $directory, $version, $matrix->{include})) {
        print "No new successful publications to record\n";
        return;
    }
    write_json('versions.json', $history);
    run('git', 'config', 'user.name', 'github-actions[bot]');
    run('git', 'config', 'user.email', '41898282+github-actions[bot]@users.noreply.github.com');
    run('git', 'add', 'versions.json');
    run('git', 'commit', '-m', "Record published bases for $version");
    # Registry publication has already happened. If this push fails, the next
    # automatic run may rebuild bases whose success was not recorded.
    run('git', 'push');
}

sub release_main {
    my $command = shift @ARGV // '';
    if ($command eq 'prepare') { prepare(); }
    elsif ($command eq 'record') { record(); }
    else { die "usage: $0 prepare|record\n"; }
}

release_main() unless caller;
1;

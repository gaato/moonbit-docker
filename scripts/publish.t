use strict;
use warnings;
no warnings 'once'; # Test doubles replace functions loaded by require.
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use Cwd qw(getcwd);
require "$FindBin::Bin/publish.pl";

my @cases = (
    ['new series', '0.10.9+aaa', [], 0, [qw(0.10.9 0.10.9-aaa 0.10)]],
    ['numeric patch ordering', '0.10.10+bbb', ['0.10.9+aaa'], 1,
        [qw(0.10.10 0.10.10-bbb 0.10 latest)]],
    ['older rebuild', '0.10.9+aaa', ['0.10.10+bbb'], 0, [qw(0.10.9 0.10.9-aaa)]],
    ['same patch rebuild', '0.10.10+ccc', ['0.10.10+bbb'], 0,
        [qw(0.10.10 0.10.10-ccc 0.10)]],
    ['other series', '0.10.11+ccc', ['0.11.0+ddd', '0.100.99+eee'], 0,
        [qw(0.10.11 0.10.11-ccc 0.10)]],
);
for my $case (@cases) {
    my ($name, $version, $history, $latest, $expected) = @$case;
    is_deeply([release_tags($version, $latest, $history)], $expected, $name);
}

eval { release_tags('nightly', 0, []) };
like($@, qr/Invalid release version/, 'invalid release rejected');
eval { read_versions('/nonexistent/moonbit-versions.txt') };
like($@, qr/Cannot read/, 'missing history fails closed');

my $dir = tempdir(CLEANUP => 1);
{
    no warnings 'redefine';
    my $cwd = getcwd();
    chdir $dir or die $!;
    open my $file, '>', 'versions.txt' or die $!;
    print {$file} "0.10.9+aaa\n";
    close $file or die $!;
    my @git;
    local *main::run = sub { push @git, [@_] };
    record_version('0.10.10+bbb', ['0.10.9+aaa']);
    is_deeply([read_versions('versions.txt')], ['0.10.9+aaa', '0.10.10+bbb'], 'append published release');
    is_deeply($git[-1], ['git', 'push'], 'push version record');
    @git = ();
    record_version('0.10.10+bbb', [read_versions('versions.txt')]);
    is(scalar @git, 0, 'existing release is not committed again');
    chdir $cwd or die $!;
}
my %digests = (trixie => ['a' x 64, 'b' x 64], bookworm => ['c' x 64, 'd' x 64]);
for my $base (keys %digests) {
    mkdir "$dir/$base" or die $!;
    for my $digest (@{$digests{$base}}) {
        open my $file, '>', "$dir/$base/$digest" or die $!;
        close $file or die $!;
    }
}

my @commands;
{
    no warnings 'redefine';
    local *main::run = sub { push @commands, [@_] };
    publish('ghcr.io/test/moonbit', '0.10.10+bbb', 1, $dir, ['0.10.9+aaa']);
}
my @creates = grep { $_->[3] eq 'create' } @commands;
is(scalar @creates, 2, 'one manifest per base');
is_deeply($creates[0], ['docker', 'buildx', 'imagetools', 'create',
    (map { ('-t', "ghcr.io/test/moonbit:$_") } qw(0.10.10 0.10.10-bbb 0.10 latest)),
    (map { "ghcr.io/test/moonbit\@sha256:$_" } @{$digests{trixie}})], 'trixie tags and sources');
is_deeply($creates[1], ['docker', 'buildx', 'imagetools', 'create',
    (map { ('-t', "ghcr.io/test/moonbit:$_-bookworm") } qw(0.10.10 0.10.10-bbb 0.10 latest)),
    (map { "ghcr.io/test/moonbit\@sha256:$_" } @{$digests{bookworm}})], 'bookworm tags and sources');

for my $statuses ([200, 404], [404, 200], [404, 404], [200, 200], [404, 503]) {
    @commands = ();
    my @urls;
    my @responses = @$statuses;
    {
        no warnings 'redefine';
        local *main::run = sub { push @commands, [@_] };
        local *main::capture = sub {
            return '{"token":"test-token"}' if $_[1] eq '-fsS';
            push @urls, $_[-1];
            return shift @responses;
        };
        eval { publish('ghcr.io/test/moonbit', 'nightly', 0, $dir, []) };
    }
    if ($statuses->[1] == 503) {
        like($@, qr/HTTP 503/, 'registry failure aborts');
        is(scalar @commands, 0, 'both bases checked before any publication');
        next;
    }
    is($@, '', "nightly statuses @$statuses succeed");
    my ($date) = $urls[0] =~ /nightly-(\d{8})\z/;
    ok($date, 'UTC date-shaped tag');
    like($urls[1], qr/nightly-$date-bookworm\z/, 'same date for both bases');
    my @nightly_creates = grep { $_->[3] eq 'create' } @commands;
    for my $i (0, 1) {
        my $suffix = $i ? '-bookworm' : '';
        my @expected = ('docker', 'buildx', 'imagetools', 'create',
            '-t', "ghcr.io/test/moonbit:nightly$suffix");
        push @expected, '-t', "ghcr.io/test/moonbit:nightly-$date$suffix" if $statuses->[$i] == 404;
        push @expected, map { "ghcr.io/test/moonbit\@sha256:$_" }
            @{$digests{$i ? 'bookworm' : 'trixie'}};
        is_deeply($nightly_creates[$i], \@expected, 'only absent dated tags are published');
    }
}

{
    no warnings 'redefine';
    local *main::capture = sub { die "curl failed\n" };
    eval { dated_tag_exists('test/moonbit', 'nightly-20260923', 'token') };
    like($@, qr/curl failed/, 'transport failure is not treated as a missing tag');
}

{
    no warnings 'redefine';
    my $recorded = 0;
    local %ENV = (%ENV, IMAGE => 'ghcr.io/test/moonbit', VERSION => '0.10.10+bbb', DIGEST_DIR => $dir);
    local *main::read_versions = sub { return '0.10.9+aaa' };
    local *main::record_version = sub { $recorded++ };
    local *main::run = sub { die "docker failed\n" if $_[0] eq 'docker' };
    eval { main() };
    like($@, qr/docker failed/, 'publication failure propagates');
    is($recorded, 0, 'failed publication does not record version');
}

{
    no warnings 'redefine';
    my @events;
    local %ENV = (%ENV, IMAGE => 'ghcr.io/test/moonbit', VERSION => '0.10.10+bbb', DIGEST_DIR => $dir);
    local *main::run = sub { push @events, join(' ', @_) };
    local *main::read_versions = sub { push @events, 'read history'; return '0.10.11+ccc' };
    local *main::record_version = sub { push @events, 'record version' };
    main();
    is_deeply([@events[0, 1]], ['git pull --ff-only', 'read history'], 'refresh before reading history');
    unlike(join("\n", @events), qr/:0\.10(?:\s|$)/, 'rerun with newer history does not roll minor back');
    is($events[-1], 'record version', 'record only after all publications');
}

unlink "$dir/bookworm/$digests{bookworm}[0]" or die $!;
@commands = ();
{
    no warnings 'redefine';
    local *main::run = sub { push @commands, [@_] };
    eval { publish('ghcr.io/test/moonbit', '0.10.10+bbb', 1, $dir, []) };
}
like($@, qr/Expected two architecture digests/, 'missing architecture fails');
is(scalar @commands, 0, 'incomplete digests cannot partially publish');

done_testing;

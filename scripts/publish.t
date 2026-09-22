use strict;
use warnings;
no warnings 'once';
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use Cwd qw(getcwd);
require "$FindBin::Bin/release.pl";

my $bases = read_bases();
my $stored_history = read_versions('versions.json');
is_deeply([sort keys %$stored_history], [sort map { $_->{name} } @$bases], 'history covers configured bases');

my @cases = (
    ['new series', '0.10.9+aaa', [], 0, [qw(0.10.9 0.10.9-aaa 0.10)]],
    ['numeric ordering', '0.10.10+bbb', ['0.10.9+aaa'], 1, [qw(0.10.10 0.10.10-bbb 0.10 latest)]],
    ['older rebuild', '0.10.9+aaa', ['0.10.10+bbb'], 0, [qw(0.10.9 0.10.9-aaa)]],
    ['same patch', '0.10.10+ccc', ['0.10.10+bbb'], 0, [qw(0.10.10 0.10.10-ccc 0.10)]],
    ['other series', '0.10.11+ccc', ['0.11.0+ddd', '0.100.99+eee'], 0, [qw(0.10.11 0.10.11-ccc 0.10)]],
);
for my $case (@cases) {
    my ($name, $version, $history, $latest, $expected) = @$case;
    is_deeply([release_tags($version, $latest, $history)], $expected, $name);
}
eval { release_tags('nightly', 0, []) };
like($@, qr/Invalid release/, 'invalid release rejected');
eval { read_versions('/nonexistent/moonbit-versions.json') };
like($@, qr/Cannot read/, 'missing history fails closed');

my $dir = tempdir(CLEANUP => 1);
my $cwd = getcwd();
chdir $dir or die $!;
write_json('bases.json', $bases);
write_json('versions.json', {});
mkdir 'digests' or die $!;
my %digests;
my $serial = 0;
for my $base (@$bases) {
    my $name = $base->{name};
    mkdir "digests/$name" or die $!;
    for my $arch ('amd64', 'arm64') {
        my $digest = sprintf 'sha256:%064x', ++$serial;
        $digests{$name}{$arch} = $digest;
        open my $file, '>', "digests/$name/$arch.digest" or die $!;
        print {$file} "$digest\n";
        close $file or die $!;
    }
}

my $version = '0.10.10+bbb';
my $history = { trixie => ['0.10.11+ccc'] };
for my $base (@$bases) {
    my @commands;
    {
        no warnings 'redefine';
        local *main::run = sub { push @commands, [@_] };
        publish('ghcr.io/test/moonbit', $version, 0, 'digests', $history, $base);
    }
    my @tags = ('0.10.10', '0.10.10-bbb');
    push @tags, '0.10' unless $base->{name} eq 'trixie';
    is_deeply($commands[0], ['docker', 'buildx', 'imagetools', 'create',
        (map { ('-t', "ghcr.io/test/moonbit:$_$base->{suffix}") } @tags),
        (map { "ghcr.io/test/moonbit\@$digests{$base->{name}}{$_}" } qw(amd64 arm64))],
        "$base->{name}: isolated tags, history, and sources");

    for my $status (200, 404, 503) {
        @commands = ();
        my $url;
        {
            no warnings 'redefine';
            local *main::run = sub { push @commands, [@_] };
            local *main::capture = sub {
                return '{"token":"test-token"}' if $_[1] eq '-fsS';
                $url = $_[-1];
                return "$status";
            };
            eval { publish('ghcr.io/test/moonbit', 'nightly', 0, 'digests', {}, $base) };
        }
        if ($status == 503) {
            like($@, qr/HTTP 503/, "$base->{name}: lookup error propagated");
            is(scalar @commands, 0, 'no tags changed on lookup error');
        } else {
            is($@, '', "$base->{name}: nightly status $status succeeds");
            my ($date) = $url =~ /nightly-(\d{8})/;
            ok($date, 'publication has a UTC date');
            my $dated = "ghcr.io/test/moonbit:nightly-$date$base->{suffix}";
            my @expected = ('docker', 'buildx', 'imagetools', 'create',
                '-t', "ghcr.io/test/moonbit:nightly$base->{suffix}");
            push @expected, '-t', $dated if $status == 404;
            push @expected, map { "ghcr.io/test/moonbit\@$digests{$base->{name}}{$_}" } qw(amd64 arm64);
            is_deeply($commands[0], \@expected, 'dated tag is created only when absent');
            is($commands[-1][-1], $dated, 'dated tag inspected even if preserved');
        }
    }
}

# One base's incomplete architecture set does not prevent another publication.
unlink 'digests/trixie/arm64.digest' or die $!;
{
    no warnings 'redefine';
    my @commands;
    local *main::run = sub { push @commands, [@_] };
    eval { publish('ghcr.io/test/moonbit', $version, 0, 'digests', {}, $bases->[0]) };
    like($@, qr/Missing arm64/, 'missing architecture blocks its base');
    is(scalar @commands, 0, 'failed base publishes nothing');
    publish('ghcr.io/test/moonbit', $version, 0, 'digests', {}, $bases->[1]);
    ok(@commands, 'another base can still publish');
}

# Publisher never commits history; receipts follow successful publication only.
{
    no warnings 'redefine';
    local %ENV = (%ENV, IMAGE => 'ghcr.io/test/moonbit', VERSION => $version,
        BASE => 'bookworm', DIGEST_DIR => 'digests', RECEIPT_DIR => 'receipts');
    local *main::run = sub { die "docker failed\n" if $_[0] eq 'docker' };
    eval { main() };
    like($@, qr/docker failed/, 'publication failure propagates');
    ok(!-e 'receipts/bookworm.json', 'failed publication creates no receipt');
    my @commands;
    local *main::run = sub { push @commands, [@_] };
    main();
    is_deeply(read_json('receipts/bookworm.json'), {base => 'bookworm', version => $version}, 'success receipt');
    ok(!grep({ $_->[0] eq 'git' && $_->[1] eq 'push' } @commands), 'publisher cannot push history');
}

my $merged = {};
ok(merge_receipts($merged, 'receipts', $version, $bases), 'partial success recorded');
is_deeply($merged, {bookworm => [$version]}, 'only successful base recorded');
ok(!merge_receipts($merged, 'receipts', $version, $bases), 'duplicate receipt is idempotent');
my $selected = select_bases($bases, $merged, $version, 'all', 0);
is_deeply([map { $_->{name} } @$selected], [map { $_->{name} } grep { $_->{name} ne 'bookworm' } @$bases], 'retry only unpublished bases');
is_deeply(select_bases($bases, $merged, $version, 'bookworm', 0), [], 'published selection skips');
is_deeply(select_bases($bases, $merged, $version, 'bookworm', 1), [$bases->[1]], 'explicit rebuild allowed');
is_deeply(select_bases($bases, $merged, '0.10.11+ccc', 'all', 0), $bases, 'new latest supersedes old pending releases');
is_deeply(select_bases($bases, $merged, 'nightly', 'all', 0), $bases, 'nightly always selects every base');
my %complete = map { $_->{name} => [$version] } @$bases;
is_deeply(select_bases($bases, \%complete, $version, 'all', 0), [], 'all published skips build');
eval { select_bases($bases, {}, $version, 'unknown-base', 0) };
like($@, qr/Unknown base/, 'unknown base rejected');

write_json('receipts/tumbleweed.json', {base => 'tumbleweed', version => '0.10.9+aaa'});
my $untouched = {};
eval { merge_receipts($untouched, 'receipts', $version, $bases) };
like($@, qr/Invalid publication receipt/, 'wrong-version receipt rejected');
is_deeply($untouched, {}, 'invalid receipts do not partially alter history');
unlink 'receipts/tumbleweed.json' or die $!;
write_json('receipts/unknown.json', {base => 'unknown', version => $version});
eval { merge_receipts({}, 'receipts', $version, $bases) };
like($@, qr/Invalid publication receipt/, 'unknown-base receipt rejected');
unlink 'receipts/unknown.json' or die $!;
ok(!merge_receipts({}, 'absent', $version, $bases), 'no successful publications is a no-op');

{
    no warnings 'redefine';
    local %ENV = (%ENV, VERSION => $version, RECEIPT_DIR => 'receipts',
        TARGETS => JSON::PP->new->encode({include => $bases}));
    my @commands;
    local *main::run = sub { push @commands, [@_] };
    record();
    is_deeply(read_versions('versions.json'), {bookworm => [$version]}, 'collector persists partial successes');
    is_deeply($commands[-1], ['git', 'push'], 'one collector pushes history');
    @commands = ();
    record();
    is_deeply(\@commands, [['git', 'pull', '--ff-only']], 'collector rerun does not create duplicate commit');
    write_json('versions.json', {});
    local *main::run = sub { die "push failed\n" if $_[1] eq 'push' };
    eval { record() };
    like($@, qr/push failed/, 'history push failure is not swallowed');
}

# The resolver emits a usable matrix and refreshes history before selection.
{
    no warnings 'redefine';
    write_json('versions.json', {bookworm => [$version]});
    local %ENV = (%ENV, CHANNEL => 'release', INPUT_VERSION => '', INPUT_BASE => 'all', GITHUB_OUTPUT => 'outputs');
    my @commands;
    local *main::run = sub { push @commands, [@_] };
    local *main::capture = sub { return '{"items":[{"name":"moonc","version":"v0.10.10+bbb (date)"}]}' };
    prepare();
    open my $output, '<', 'outputs' or die $!;
    my %outputs = map { chomp; split /=/, $_, 2 } <$output>;
    close $output;
    is($outputs{build}, 'true', 'resolver schedules missing bases');
    is($outputs{latest}, 'true', 'resolver identifies latest');
    is($outputs{version}, $version, 'resolver strips prefix and date');
    is_deeply(decode_json($outputs{matrix})->{include}, $selected, 'matrix matches retry selection');
    is_deeply($commands[0], ['git', 'pull', '--ff-only'], 'history refreshed before selection');
}

chdir $cwd or die $!;
done_testing;

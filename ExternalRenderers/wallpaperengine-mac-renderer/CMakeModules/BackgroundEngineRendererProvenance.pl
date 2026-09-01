#!/usr/bin/perl
use strict;
use warnings;

use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use File::Basename qw(basename);
use File::Find qw(find);
use File::Spec;

sub fail {
    my ($message) = @_;
    print STDERR "$message\n";
    exit 1;
}

(@ARGV == 1 || @ARGV == 2)
    or fail("usage: $0 /path/to/wallpaperengine-mac-renderer [--inventory|--binding]");
my ($requested_root, $mode) = @ARGV;
defined($mode) && $mode ne '--inventory' && $mode ne '--binding'
    and fail("Unsupported renderer source fingerprint mode: $mode");
-d $requested_root && !-l $requested_root
    or fail("Renderer source root is missing or unsafe: $requested_root");
my $root = abs_path($requested_root)
    or fail("Unable to resolve renderer source root: $requested_root");

my @exact_inputs = (
    '.background-engine-build-version',
    '.background-engine-source-ref',
    'CMakeLists.txt',
);
my @input_roots = ('CMakeModules', 'src');
my %excluded_relative_paths = map { $_ => 1 } (
    'src/External/Catch2/third_party/clara.hpp',
    'src/External/Catch2/tools/misc/SelfTest.vcxproj.user',
    'src/External/stb/tests/oversample/oversample.exe',
);
my @relative_paths;

for my $relative (@exact_inputs) {
    my $path = File::Spec->catfile($root, split('/', $relative));
    -f $path && !-l $path
        or fail("Canonical renderer source input is missing or unsafe: $relative");
    push @relative_paths, $relative;
}

for my $relative_root (@input_roots) {
    my $path = File::Spec->catdir($root, $relative_root);
    -d $path && !-l $path
        or fail("Canonical renderer source directory is missing or unsafe: $relative_root");
    find(
        {
            no_chdir => 1,
            follow => 0,
            wanted => sub {
                my $candidate = $File::Find::name;
                my $name = basename($candidate);
                if (-d $candidate && ($name eq '.git' || $name eq 'build'
                        || $name eq 'CMakeFiles' || $name eq '.cache')) {
                    $File::Find::prune = 1;
                    return;
                }
                my $relative = File::Spec->abs2rel($candidate, $root);
                $relative =~ tr{\\}{/};
                return if $excluded_relative_paths{$relative};
                -l $candidate
                    and fail("Canonical renderer source contains a symbolic link: $candidate");
                return unless -f $candidate;
                $relative !~ /[\t\r\n]/
                    or fail("Canonical renderer source path contains an unsafe character: $relative");
                push @relative_paths, $relative;
            },
        },
        $path,
    );
}

my %seen;
@relative_paths = sort grep { !$seen{$_}++ } @relative_paths;
@relative_paths
    or fail("Canonical renderer source inventory is empty: $root");

my $aggregate = Digest::SHA->new(256);
my @inventory;
for my $relative (@relative_paths) {
    my $path = File::Spec->catfile($root, split('/', $relative));
    open my $handle, '<:raw', $path
        or fail("Unable to read canonical renderer source input $relative: $!");
    my $digest = Digest::SHA->new(256);
    $digest->addfile($handle);
    close $handle
        or fail("Unable to close canonical renderer source input $relative: $!");
    my $file_hash = $digest->hexdigest;
    my $record = "$relative\t$file_hash\n";
    $aggregate->add($record);
    push @inventory, $record;
}

if (defined($mode) && $mode eq '--inventory') {
    print @inventory;
    exit 0;
}

sub read_single_line {
    my ($relative, $pattern, $description) = @_;
    my $path = File::Spec->catfile($root, split('/', $relative));
    open my $handle, '<:raw', $path
        or fail("Unable to read $description: $!");
    local $/;
    my $value = <$handle>;
    close $handle
        or fail("Unable to close $description: $!");
    $value =~ s/\r?\n\z//;
    $value =~ $pattern
        or fail("Renderer $description is malformed: $relative");
    return $value;
}

my $version = read_single_line(
    '.background-engine-build-version',
    qr/\A[0-9A-Za-z][0-9A-Za-z._-]{0,63}\z/,
    'build version',
);
my $source_ref = read_single_line(
    '.background-engine-source-ref',
    qr/\A[0-9a-f]{40}\z/,
    'upstream source revision',
);
my $fingerprint = $aggregate->hexdigest;
my $file_count = scalar(@relative_paths);

if (defined($mode) && $mode eq '--binding') {
    print "background-engine-renderer-provenance-v1"
        . "|$version|$source_ref|$fingerprint|$file_count\n";
    exit 0;
}

print "renderer-version\t$version\n";
print "upstream-source-ref\t$source_ref\n";
print "source-fingerprint\t$fingerprint\n";
print "source-file-count\t$file_count\n";

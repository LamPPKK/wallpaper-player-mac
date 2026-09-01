#!/usr/bin/perl
use strict;
use warnings;

use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Spec;

(@ARGV == 1 || @ARGV == 2) or die(
    "usage: $0 /path/to/wallpaperengine-mac-renderer [--inventory|--binding]\n"
);
my $script = abs_path($0)
    or die("Unable to resolve trusted renderer provenance wrapper: $0\n");
my $repository_root = dirname(dirname($script));
my $tool = File::Spec->catfile(
    $repository_root,
    'ExternalRenderers',
    'wallpaperengine-mac-renderer',
    'CMakeModules',
    'BackgroundEngineRendererProvenance.pl'
);
-f $tool && !-l $tool
    or die("Trusted renderer provenance implementation is missing or unsafe: $tool\n");
exec '/usr/bin/perl', $tool, @ARGV
    or die("Unable to execute trusted renderer provenance implementation: $!\n");

#!/usr/bin/perl
# OpenSuperWhisper media-remote launcher.
#
# macOS 15.4+ restricts the private MediaRemote framework to Apple platform
# binaries. /usr/bin/perl is one, so it loads our helper dylib into its own
# (entitled) process and calls one exported symbol. Our app cannot do this
# directly - it would get empty/false data back.
#
# Usage:
#   /usr/bin/perl osw-media-remote.pl <helper-dylib-path> <get|pause|play>
#
# "get" prints "true"/"false" (is anything playing); "pause"/"play" send the
# discrete MediaRemote command.

use strict;
use warnings;
use DynaLoader;

my ($lib, $command) = @ARGV;
die "usage: $0 <helper-dylib> <get|pause|play>\n"
  unless defined $lib && defined $command;

my %symbol_for = (
    get   => 'osw_media_get',
    pause => 'osw_media_pause',
    play  => 'osw_media_play',
);
my $symbol_name = $symbol_for{$command}
  or die "unknown command: $command\n";

my $handle = DynaLoader::dl_load_file($lib, 0)
  or die "failed to load helper dylib: $lib\n";
my $symbol = DynaLoader::dl_find_symbol($handle, $symbol_name)
  or die "symbol not found: $symbol_name\n";

# perl invokes the C symbol as an XSUB; our helper ignores the perl arguments.
DynaLoader::dl_install_xsub("main::entry", $symbol);
entry();

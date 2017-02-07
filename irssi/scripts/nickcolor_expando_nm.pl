use Irssi;
use strict;

our $VERSION = '0.1.2';
our %IRSSI = (
	authors		=> 'Nei',
	name		=> 'nickcolor_expando',
	description	=> 'colourise nicks',
	license		=> 'GPL v2',
);

# based on nm.pl by BC-bd
# inspired by nickcolor.pl by Timo Sirainen and Ian Peters
# DO NOT LOAD IF YOU ARE ALREADY USING nm!
#
#########
# USAGE
###
#
# add the colour expando to the format (themes are not supported)
#
#   /format pubmsg {pubmsgnick $2 {pubnick $nickcolor$0}}$1
#
# use
#
# 	/neatcolor help
#
# for help on available commands
#
#########
# OPTIONS
#########

my $help = "
/set neat_colors <string>
    Use these colours when colourizing nicks, eg:

        /set neat_colors yYrR

    See the file formats.txt on an explanation of what colours are
    available.

/set neat_ignorechars <str>
    * str : regular expression used to filter out unwanted characters in
            nicks. this can be used to assign the same colour for similar
            nicks, e.g. foo and foo_:

                /set neat_ignorechars [_]

";


my (%saved_colors, @colors, $ignore_re, $color, %commands);

sub msg_line_tag {
    my ($srv, $msg, $nick, $addr, $targ) = @_;
	$color = $saved_colors{$nick} // '';
}

sub msg_line_clear {
    clear_ref();
}

sub prnt_clear_public {
    my ($dest) = @_;
    clear_ref() if $dest->{level} & MSGLEVEL_PUBLIC;
}

sub clear_ref {
	$color = '';
}

# a new nick was created
sub sig_newNick {
	my ($channel, $nick) = @_;

	return if exists $saved_colors{$nick->{nick}};

	$saved_colors{$nick->{nick}} = '%'.nick_to_color($nick->{nick});
}

# something changed
sub sig_changeNick {
	my ($channel, $nick, $old_nick) = @_;

	# if no saved colour exists, we already handled this nickchange. irssi
	# generates one signal per channel the nick is in, so if you share more
	# than one channel with this nick, you'd lose the colouring.
	return unless exists $saved_colors{$old_nick};

	# we need to update the saved colours hash independent of nick length
	$saved_colors{$nick->{nick}} = $saved_colors{$old_nick};
	delete $saved_colors{$old_nick};
}

sub nick_to_color {
    my ($string) = @_;
    chomp $string;

    $string =~ s/$ignore_re//g;

    my $hash;
    use integer;
    # one-at-a-time hash
    $hash = 0x5065526c + length $string;
    for my $ord (unpack 'U*', $string) {
	$hash += $ord;
	$hash += $hash << 10;
	$hash &= 0xffffffff;
	$hash ^= $hash >> 6;
    }
    $hash += $hash << 3;
    $hash &= 0xffffffff;
    $hash ^= $hash >> 11;
    $hash = $hash + ($hash << 15);
    $hash &= 0xffffffff;
    return $colors[$hash % ($#colors + 1)];
}

sub sig_setup {
	@colors = Irssi::settings_get_str('neat_colors') =~ /(x..|.)/ig;
	$ignore_re = Irssi::settings_get_str('neat_ignorechars');
}

# make sure that every nick has an assigned colour
sub assert_colors {
	for (Irssi::channels()) {
		for ($_->nicks()) {
			next if exists $saved_colors{$_->{nick}};

			$saved_colors{$_->{nick}} = '%'.nick_to_color($_->{nick});
		}
	}
}

# load colours from file
sub load_colors {
	open my $fid, '<', Irssi::get_irssi_dir() . '/saved_colors' or return;

	while (<$fid>) {
		chomp;
		my ($k, $v) = split(/:/);

		# skip broken lines, those may have been introduced by nm.pl
		# version 0.3.7 and earlier
		if ($k eq '' || $v eq '') {
			next;
		}

		$saved_colors{$k} = $v;
	}

	close $fid;
}

# save colours to file
sub save_colors {
	open my $fid, '>', Irssi::get_irssi_dir() . '/saved_colors';

	print $fid "$_:$saved_colors{$_}\n" for keys %saved_colors;

	close $fid;
}

# log a line to a window item
sub neat_log {
	my ($witem, @text) = @_;

	$witem->print("nce: ".$_) for @text;
}

# show available colours
sub cmd_neatcolor_colors {
	my ($witem) = @_;

	neat_log($witem, 'Available colours: '.join('', map { '%'.$_.$_ } @colors));
}

# display the configured colour for a nick
sub cmd_neatcolor_get {
	my ($witem, $nick) = @_;

	if (!exists($saved_colors{$nick})) {
		neat_log($witem, "Error: no such nick '$nick'");
		return;
	}

	neat_log($witem, "Colour for ".$saved_colors{$nick}.$nick);
}

# display help
sub cmd_neatcolor_help {
	my ($witem, $cmd) = @_;

	if ($cmd) {
		unless (exists $commands{$cmd}) {
			neat_log($witem, "Error: no such command '$cmd'");
			return;
		}

		unless (exists $commands{$cmd}{verbose}) {
			neat_log($witem, "No additional help for '$cmd' available");
			return;
		}

		neat_log($witem, ( '', "Help for \U$cmd", '' ) );
		neat_log($witem, @{$commands{$cmd}{verbose}});
		return;
	}

	neat_log($witem, split(/\n/, $help));
	neat_log($witem, 'Available options for /neatcolor');
	neat_log($witem, "    $_: ".$commands{$_}{text}) for sort keys %commands;

	my @verbose;
	for (sort keys %commands) {
		push @verbose, $_ if exists $commands{$_}{verbose};
	}

	neat_log($witem, "Verbose help available for: '".(join ', ', @verbose)."'");
}

# list configured nicks
sub cmd_neatcolor_list {
	my ($witem) = @_;

	neat_log($witem, 'Configured nicks: '.join ', ', map { $saved_colors{$_}.$_ } sort keys %saved_colors);
	my %distribution;
	for (values %saved_colors) { $distribution{$_}++ }
	neat_log($witem, 'Colour distribution: '.join ', ', map { "%$_$_:".$distribution{'%'.$_} } sort { $distribution{'%'.$b} <=> $distribution{'%'.$a} } @colors);
}

# reset a nick to its default colour
sub cmd_neatcolor_reset {
	my ($witem, $nick) = @_;

	if ($nick eq '--all') {
		%saved_colors = ();
		assert_colors();
		neat_log($witem, "Reset all colours");
		return;
	}

	unless (exists $saved_colors{$nick}) {
		neat_log($witem, "Error: no such nick '$nick'");
		return;
	}

	$saved_colors{$nick} = '%'.nick_to_color($nick);
	neat_log($witem, 'Reset colour for '.$saved_colors{$nick}.$nick);
}

# save configured colours to disk
sub cmd_neatcolor_save {
	my ($witem) = @_;

	save_colors();

	neat_log($witem, 'colour information saved');
}

# set a colour for a nick
sub cmd_neatcolor_set {
	my ($witem, $nick, $color) = @_;

	my @found = grep(/$color/, @colors);
	if ($#found) {
		neat_log($witem, "Error: trying to set unknown colour '%$color$color%n'");
		cmd_neatcolor_colors($witem);
		return;
	}

	if ($witem->{type} ne "CHANNEL" && $witem->{type} ne "QUERY") {
		neat_log($witem, "Warning: not a Channel/Query, can not check nick!");
		neat_log($witem, "Remember, nicks are case sensitive to nickcolor_expando.pl");
	} else {
		my @nicks = grep(/^$nick$/i, map { $_->{nick} } ($witem->nicks()));

		if ($#nicks < 0) {
			neat_log($witem, "Warning: could not find nick '$nick' here");
		} else {
			if ($nicks[0] ne $nick) {
				neat_log($witem, "Warning: using '$nicks[0]' instead of '$nick'");
				$nick = $nicks[0];
			}
		}
	}

	$saved_colors{$nick} = '%'.$color;
	neat_log($witem, "Set colour for $saved_colors{$nick}$nick");
}

%commands = (
	colors => {
		text => "show available colours",
		verbose => [
			"COLORS",
			"",
			"displays all available colours",
			"",
			"You can restrict/define the list of available colours ".
			"with the help of the neat_colors setting"
		],
		func => \&cmd_neatcolor_colors,
	},
	get => {
		text => "retrieve colour for a nick",
		verbose => [
			"GET <nick>",
			"",
			"displays colour used for <nick>"
		],
		func => \&cmd_neatcolor_get,
	},
	help => {
		text => "print this help message",
		func => \&cmd_neatcolor_help,
	},
	list => {
		text => "list configured nick/colour pairs",
		func => \&cmd_neatcolor_list,
	},
	reset => {
		text => "reset colour to default",
		verbose => [
			"RESET --all|<nick>",
			"",
			"resets the colour used for all nicks or for <nick> to ",
			"its internal default",
		],
		func => \&cmd_neatcolor_reset,
	},
	save => {
		text => "save colour information to disk",
		verbose => [
			"SAVE",
			"",
			"saves colour information to disk, so that it survives ".
			"an irssi restart.",
			"",
			"Colour information will be automatically saved on /quit",
		],
		func => \&cmd_neatcolor_save,
	},
	set => {
		text => "set a specific colour for a nick",
		verbose => [
			"SET <nick> <colour>",
			"",
			"use <colour> for <nick>",
			"",
			"This command will perform a couple of sanity checks, ".
			"when called from a CHANNEL/QUERY window",
			"",
			"EXAMPLE:",
			"  /neatcolor set bc-bd r",
			"",
			"use /neatcolor COLORS to see available colours"
		],
		func => \&cmd_neatcolor_set,
	},
);

# the main command callback that gets called for all neatcolor commands
sub cmd_neatcolor {
	my ($data, $server, $witem) = @_;
	my ($cmd, $nick, $color) = split (/ /, $data);

	$cmd = lc($cmd);

	# make sure we have a valid witem to print text to
	$witem = Irssi::active_win() unless $witem;

	unless (exists $commands{$cmd}) {
		neat_log($witem, "Error: unknown command '$cmd'");
		&{$commands{help}{func}}($witem) if exists $commands{help};
		return;
	}

	&{$commands{$cmd}{func}}($witem, $nick, $color);
}

{
	my %format2control = (
		'F' => "\cDa", '_' => "\cDc", '|' => "\cDe", '#' => "\cDi", "n" => "\cDg", "N" => "\cDg",
		'U' => "\c_", '8' => "\cV", 'I' => "\cDf",
	   );
	my %bg_base = (
		'0'   => '0', '4' => '1', '2' => '2', '6' => '3', '1' => '4', '5' => '5', '3' => '6', '7' => '7',
		'x08' => '8', 'x09' => '9', 'x0a' => ':', 'x0b' => ';', 'x0c' => '<', 'x0d' => '=', 'x0e' => '>', 'x0f' => '?',
	   );
	my %fg_base = (
		'k' => '0', 'b' => '1', 'g' => '2', 'c' => '3', 'r' => '4', 'm' => '5', 'p' => '5', 'y' => '6', 'w' => '7',
		'K' => '8', 'B' => '9', 'G' => ':', 'C' => ';', 'R' => '<', 'M' => '=', 'P' => '=', 'Y' => '>', 'W' => '?',
	   );
	my @ext_color_off = (
		'.', '-', ',',
		'+', "'", '&',
	   );
	sub format_expand {
		$_[0] =~ s{%(Z.{6}|z.{6}|X..|x..|.)}{
			my $c = $1;
			if (exists $format2control{$c}) {
				$format2control{$c}
			}
			elsif (exists $bg_base{$c}) {
				"\cD/$bg_base{$c}"
			}
			elsif (exists $fg_base{$c}) {
				"\cD$fg_base{$c}/"
			}
			elsif ($c =~ /^[{}%]$/) {
				$c
			}
			elsif ($c =~ /^(z|Z)([[:xdigit:]]{2})([[:xdigit:]]{2})([[:xdigit:]]{2})$/) {
				my $bg = $1 eq 'z';
				my (@rgb) = map { hex $_ } $2, $3, $4;
				my $x = $bg ? 0x1 : 0;
				my $out = "\cD" . (chr -13 + ord '0');
				for (my $i = 0; $i < 3; ++$i) {
					if ($rgb[$i] > 0x20)   { $out .= chr $rgb[$i]; }
					else { $x |= 0x10 << $i; $out .= chr 0x20 + $rgb[$i]; }
				}
				$out .= chr 0x20 + $x;
				$out
			}
			elsif ($c =~ /^(x)(?:0([[:xdigit:]])|([1-6])(?:([0-9])|([a-z]))|7([a-x]))$/i) {
				my $bg = $1 eq 'x';
				my $col = defined $2 ? hex $2
					: defined $6 ? 232 + (ord lc $6) - (ord 'a')
					: 16 + 36 * ($3 - 1) + (defined $4 ? $4 : 10 + (ord lc $5) - (ord 'a'));
				if ($col < 0x10) {
					my $chr = chr $col + ord '0';
					"\cD" . ($bg ? "/$chr" : "$chr/")
				}
				else {
					"\cD" . $ext_color_off[($col - 0x10) / 0x50 + $bg * 3] . chr (($col - 0x10) % 0x50 - 1 + ord '0')
				}
			}
			else {
				"%$c"
			}
        }ger;
	}
}

sub expando_neatcolor {
	return format_expand($color);
}

sub get_nick_color {
	my ($nick, $format) = @_;
	my $col = $saved_colors{$nick};
	$format ? format_expand($col) : $col
}

sub get_nick_color2 {
	my ($net, $chan, $nick, $format) = @_;
	my $col = $saved_colors{$nick};
	$format ? format_expand($col) : $col
}

Irssi::expando_create('nickcolor', \&expando_neatcolor, {
	'message public' 	 => 'none',
	'message own_public' => 'none'
});

Irssi::settings_add_str('misc', 'neat_colors', 'rRgGybBmMcCX42X3AX5EX4NX3HX3CX32');
Irssi::settings_add_str('misc', 'neat_ignorechars', '');

Irssi::command_bind('neatcolor', 'cmd_neatcolor');

Irssi::signal_add({
    'message public'	      => 'msg_line_tag',
    'message own_public'      => 'msg_line_clear',
    'print text' => 'prnt_clear_public',
	'nicklist new' 			  => 'sig_newNick',
	'nicklist changed' 		  => 'sig_changeNick',
});
Irssi::signal_add_last('setup changed' => 'sig_setup');

sig_setup;
$color = '';

load_colors();
assert_colors();

# we need to add this signal _after_ the colours have been loaded, to make sure
# no race condition exists wrt colour saving
Irssi::signal_add('gui exit', 'save_colors');

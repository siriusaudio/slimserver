package Slim::Web::Settings::Server::PlayConfig;

# Lyrion Music Server Copyright 2024 Lyrion Community.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;
use base qw(Slim::Web::Settings);

use JSON::XS::VersionOneAndTwo;
use File::Slurp;
use Slim::Utils::Log;

my $log = logger('server.playconfig');

my $CONFIG_FILE = '/var/lib/squeezeboxserver/play_config.json';

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLAY_CONFIG_SETTINGS');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('settings/server/playconfig.html');
}

sub handler {
	my ($class, $client, $paramRef) = @_;

	if ($paramRef->{'saveSettings'}) {
		my $dsd_base_pref = $paramRef->{'pref_dsd_base'};
		my $dsd_base = 48000;
		if (defined $dsd_base_pref) {
			if ($dsd_base_pref =~ /^(?:auto|automatic)$/i) {
				$dsd_base = 'Automatic';
			} elsif ($dsd_base_pref =~ /^\d+$/) {
				$dsd_base = int($dsd_base_pref);
			}
		}

		# Validate and clamp phase to 0-100 range
		my $phase = int($paramRef->{'pref_phase'} || 0);
		$phase = 0 if $phase < 0;
		$phase = 100 if $phase > 100;

		# Merge into existing config so remote_player_* and other keys survive.
		my $config = _loadConfig();
		$config->{dsd_rate} = int($paramRef->{'pref_dsd_rate'} || 256);
		$config->{conversion_method} = $paramRef->{'pref_conversion_method'} || 'Original';
		$config->{pcm_conversion_rate} = int($paramRef->{'pref_pcm_conversion_rate'} || 48000);
		$config->{alsa_card} = $paramRef->{'pref_alsa_card'} || 'default';
		$config->{dsd_base} = $dsd_base;
		$config->{use_mmap} = int($paramRef->{'pref_use_mmap'} || 0);
		$config->{fix_volume} = int($paramRef->{'pref_fix_volume'} || 0);
		$config->{hold_audio_device} = int($paramRef->{'pref_hold_audio_device'} || 0);
		$config->{phase} = $phase;
		$config->{extreme_mode} = int($paramRef->{'pref_extreme_mode'} || 0);

		if (_saveConfig($config, $client)) {
			$paramRef->{'warning'} = '<span id="popupWarning">' . Slim::Utils::Strings::string("SETUP_PLAYCONFIG_SAVED") . '</span>';
		} else {
			$paramRef->{'warning'} = '<span id="popupError">' . Slim::Utils::Strings::string("SETUP_PLAYCONFIG_ERROR") . '</span>';
		}
	}

	# Load current config
	my $config = _loadConfig();
	$paramRef->{'prefs'}->{'dsd_rate'} = $config->{'dsd_rate'};
	$paramRef->{'prefs'}->{'conversion_method'} = $config->{'conversion_method'};
	$paramRef->{'prefs'}->{'pcm_conversion_rate'} = $config->{'pcm_conversion_rate'};
	$paramRef->{'prefs'}->{'alsa_card'} = $config->{'alsa_card'};
	$paramRef->{'prefs'}->{'dsd_base'} = $config->{'dsd_base'};
	$paramRef->{'prefs'}->{'use_mmap'} = $config->{'use_mmap'};
	$paramRef->{'prefs'}->{'fix_volume'} = $config->{'fix_volume'};
	$paramRef->{'prefs'}->{'hold_audio_device'} = $config->{'hold_audio_device'};
	$paramRef->{'prefs'}->{'phase'} = $config->{'phase'};
	$paramRef->{'prefs'}->{'extreme_mode'} = $config->{'extreme_mode'};

	# Get available ALSA cards
	$paramRef->{'alsa_cards'} = _getAlsaCards();

	return $class->SUPER::handler($client, $paramRef);
}

sub _loadConfig {
	my $config;
	
	if (-e $CONFIG_FILE && -r $CONFIG_FILE) {
		eval {
			my $json = read_file($CONFIG_FILE);
			$config = decode_json($json);
		};
		
		if ($@) {
			$log->error("Failed to load play_config.json: $@");
		}
	}
	
	# Return defaults if file doesn't exist or failed to load
	$config ||= {
		dsd_rate => 256,
		conversion_method => 'DSD',
		pcm_conversion_rate => 48000,
		alsa_card => 'hw:2,0',
		dsd_base => 48000,
		use_mmap => 1,
		fix_volume => 0,
		hold_audio_device => 0,
		phase => 37,
		extreme_mode => 0,
	};

	if (exists $config->{convert_options} && !exists $config->{conversion_method}) {
		$config->{conversion_method} = delete $config->{convert_options};
	}

	if (exists $config->{pcm_rate} && !exists $config->{pcm_conversion_rate}) {
		$config->{pcm_conversion_rate} = delete $config->{pcm_rate};
	}

	if (exists $config->{use_volume} && !exists $config->{fix_volume}) {
		$config->{fix_volume} = delete $config->{use_volume};
	}

	if (exists $config->{dsd_base} && defined $config->{dsd_base} && $config->{dsd_base} =~ /^(?:auto|automatic)$/i) {
		$config->{dsd_base} = 'Automatic';
	}

	return $config;
}

sub _saveConfig {
	my ($config, $client) = @_;
	
	eval {
		my $json = encode_json($config);
		write_file($CONFIG_FILE, {atomic => 1}, $json);
	};
	
	if ($@) {
		$log->error("Failed to save play_config.json: $@");
		return 0;
	}
	
	# Restart backend services after saving config
	$log->info("Restarting backend services after play_config save");

	if ($client) {
		Slim::Control::Request::executeRequest($client, ['stop']);
	}

	# Cloud / remote DAC: stop the player listeners via control channel.
	# Local installs keep the systemd path below.
	if (_isRemotePlayer($config)) {
		my $ctl = '/usr/local/bin/sirius-player-framework/server/server_control.sh';
		if (-x $ctl) {
			my $ret = system($ctl, 'stop');
			if ($ret != 0) {
				$log->warn("Failed to stop remote player via server_control: exit code $ret");
			} else {
				$log->info("Remote player stop sent after play_config save (alsa_card=$config->{alsa_card})");
			}
		} else {
			$log->warn("Remote player configured but server_control.sh missing at $ctl");
		}

		# Live volume (fix_volume off) needs sirius_volume → mpv IPC immediately,
		# not only on the next generate_audio_conversion_params run.
		my $conf = '/usr/local/bin/sirius-player-framework/supervisord.conf';
		if (-f $conf) {
			my $fix_vol = $config->{fix_volume};
			my $vol_off = (!defined $fix_vol || $fix_vol eq '0' || $fix_vol eq 'false' || $fix_vol eq '');
			my @sup = ('supervisorctl', '-c', $conf, ($vol_off ? 'start' : 'stop'), 'sirius_volume');
			my $vret = system(@sup);
			if ($vret != 0) {
				$log->warn("Failed to @{[$vol_off ? 'start' : 'stop']} sirius_volume: exit code $vret");
			} else {
				$log->info(($vol_off ? 'Started' : 'Stopped') . " sirius_volume after play_config save");
			}
		}

		$log->info("Backend service restart completed (remote)");
		return 1;
	}
	
	# Stop listener services
	my $ret1 = system('sudo', '-n', 'systemctl', 'stop', 'sirius_listen_native.service');
	if ($ret1 != 0) {
		$log->warn("Failed to stop sirius_listen_native.service: exit code $ret1");
	}
	
	my $ret2 = system('sudo', '-n', 'systemctl', 'stop', 'sirius_listen_pcm.service');
	if ($ret2 != 0) {
		$log->warn("Failed to stop sirius_listen_pcm.service: exit code $ret2");
	}

	my $ret3 = system('sudo', '-n', 'systemctl', 'stop', 'sirius_listen_dop.service');
	if ($ret3 != 0) {
		$log->warn("Failed to stop sirius_listen_dop.service: exit code $ret3");
	}
	
	# Restart player service
	my $ret4 = system('sudo', '-n', 'systemctl', 'restart', 'sirius_player.service');
	if ($ret4 != 0) {
		$log->warn("Failed to restart sirius_player.service: exit code $ret4");
	}
	
	$log->info("Backend service restart completed");
	
	return 1;
}

sub _isRemotePlayer {
	my ($config) = @_;
	return 1 if $ENV{PLAYER_HOST};
	return 1 if $config && $config->{remote_player_host};
	return 0;
}

sub _formatRates {
	my ($resolutions) = @_;
	return '' unless ref($resolutions) eq 'ARRAY' && @$resolutions;
	my @shown = map { "$_ Hz" } @$resolutions[0 .. ($#$resolutions > 2 ? 2 : $#$resolutions)];
	my $text = join(', ', @shown);
	$text .= '...' if @$resolutions > 3;
	return $text;
}

sub _formatFormats {
	my ($formats) = @_;
	return '' unless ref($formats) eq 'ARRAY' && @$formats;
	my %bits;
	my @labels;
	for my $fmt (@$formats) {
		if ($fmt =~ /^S(\d+)/) {
			$bits{$1} = 1;
		} elsif ($fmt =~ /DSD/i) {
			push @labels, $fmt unless grep { $_ eq $fmt } @labels;
		}
	}
	if (keys %bits) {
		unshift @labels, (join('/', sort { $a <=> $b } keys %bits) . '-bit');
	}
	return join(', ', @labels);
}

sub _getAlsaCardsFromCapabilities {
	my $caps_file = $ENV{DEVICE_CAPS} || '/var/lib/squeezeboxserver/device_capabilities.json';
	return () unless -e $caps_file && -r $caps_file;

	my $caps;
	eval {
		my $json = read_file($caps_file);
		$caps = decode_json($json);
	};
	if ($@) {
		$log->warn("Failed to load device_capabilities.json: $@");
		return ();
	}

	my $devices = $caps->{devices};
	return () unless ref($devices) eq 'ARRAY' && @$devices;

	my @cards;
	my %seen;
	for my $dev (@$devices) {
		next unless ref($dev) eq 'HASH';
		my $id = $dev->{id} || '';
		next unless $id;
		next if $seen{$id}++;
		push @cards, {
			id => $id,
			name => $dev->{name} || $dev->{card_id} || $id,
			shortId => $dev->{card_id} || '',
			rates => _formatRates($dev->{resolutions}),
			formats => _formatFormats($dev->{formats}),
		};
	}
	return @cards;
}

sub _getAlsaCards {
	my @cards;
	my %seen_cards;

	# Prefer player-advertised devices (cloud player / remote DAC).
	# In that setup the LMS host has no local sound cards.
	@cards = _getAlsaCardsFromCapabilities();
	if (@cards) {
		$log->info("Using " . scalar(@cards) . " ALSA card(s) from device_capabilities.json");
		unshift @cards, {
			id => 'default',
			name => 'System Default',
			rates => '',
			formats => '',
		};
		return \@cards;
	}
	
	# Try to get ALSA cards using aplay -l
	my $aplay_cmd = -x '/usr/bin/aplay' ? '/usr/bin/aplay' : 'aplay';
	my $aplay_output = `$aplay_cmd -l 2>/dev/null`;
	
	if ($aplay_output) {
		# Parse aplay -l output
		# Format: card 0: PCH [HDA Intel PCH], device 0: ALC257 Analog [ALC257 Analog]
		# or: card 2: H20 [HU300 HiFi 2.0], device 0: USB Audio [USB Audio]
		while ($aplay_output =~ /^card\s+(\d+):\s+([^\s\[]+)\s+\[([^\]]+)\]/gm) {
			my ($card_num, $card_id, $card_name) = ($1, $2, $3);
			
			next if $seen_cards{$card_num};
			$seen_cards{$card_num} = 1;
			
			# Get card capabilities using aplay -D
			my $rates = '';
			my $formats = '';
			
			eval {
				# Try to get hardware parameters
				my $hw_params = `aplay -D hw:$card_num --dump-hw-params /dev/zero 2>&1 | head -30`;
				
				# Extract sample rates
				if ($hw_params =~ /RATE:\s*\{?\s*([^\}]+)\}?/i) {
					my $rate_str = $1;
					$rate_str =~ s/\s+/ /g;
					$rate_str =~ s/^\s+|\s+$//g;
					
					# Parse rate ranges and individual rates
					my @rates;
					if ($rate_str =~ /(\d+)\s*\.\.\s*(\d+)/) {
						push @rates, "$1-$2 Hz";
					} else {
						@rates = split(/\s+/, $rate_str);
						@rates = map { "$_ Hz" } @rates if @rates;
					}
					$rates = join(', ', @rates[0..2]) if @rates;  # Show first 3
					$rates .= '...' if @rates > 3;
				}
				
				# Extract bit formats
				if ($hw_params =~ /FORMAT:\s*\{?\s*([^\}]+)\}?/i) {
					my $format_str = $1;
					$format_str =~ s/\s+/ /g;
					
					# Extract bit depths
					my %bits;
					while ($format_str =~ /S(\d+)_/g) {
						$bits{$1} = 1;
					}
					if (keys %bits) {
						$formats = join('/', sort { $a <=> $b } keys %bits) . '-bit';
					}
				}
			};
			
			push @cards, {
				id => "hw:$card_num,0",
				name => $card_name,
				shortId => $card_id,
				rates => $rates,
				formats => $formats,
			};
		}
	}

	# Fallback: read /proc/asound/cards if aplay output is not available or parsing failed.
	if (!@cards && open my $fh, '<', '/proc/asound/cards') {
		while (my $line = <$fh>) {
			if ($line =~ /^\s*(\d+)\s+\[([^\]]+)\]\s*:\s*(.+)$/) {
				my ($card_num, $card_id, $rest) = ($1, $2, $3);
				next if $seen_cards{$card_num};
				$seen_cards{$card_num} = 1;

				$card_id =~ s/\s+//g;
				my $card_name = $rest;
				$card_name =~ s/^.*?\s-\s//;

				push @cards, {
					id => "hw:$card_num,0",
					name => $card_name,
					shortId => $card_id,
					rates => '',
					formats => '',
				};
			}
		}
		close $fh;
	}
	
	# Add default card if no cards found or as first option
	unshift @cards, {
		id => 'default',
		name => 'System Default',
		rates => '',
		formats => '',
	};
	
	return \@cards;
}

1;

__END__

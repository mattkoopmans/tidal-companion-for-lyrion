package Plugins::TidalCompanion::Settings;

use strict;

use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.tidalcompanion');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_TIDALCOMPANION');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/TidalCompanion/settings/basic.html');
}

sub prefs {
	return ($prefs, qw(swapLossy scanNewReleases));
}

1;

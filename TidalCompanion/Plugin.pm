package Plugins::TidalCompanion::Plugin;

# TIDAL Companion: works alongside the TIDAL plugin and Lyrion's online
# library integration.
#   - lossy local albums play from their lossless TIDAL copy in the library
#   - lossy local albums can be looked up on TIDAL and added to favorites
#   - artists' missing albums can be added from TIDAL
#   - the library scan adds artists' new releases from TIDAL

use strict;

use base qw(Slim::Plugin::Base);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::TidalCompanion::Library;

my $log = Slim::Utils::Log->addLogCategory({
	category     => 'plugin.tidalcompanion',
	defaultLevel => 'WARN',
	description  => 'PLUGIN_TIDALCOMPANION',
});

my $prefs = preferences('plugin.tidalcompanion');

$prefs->init({
	swapLossy       => 1,
	scanNewReleases => 1,
});

sub initPlugin {
	my ($class) = @_;

	$class->SUPER::initPlugin(@_);

	if (main::WEBUI) {
		require Plugins::TidalCompanion::Settings;
		Plugins::TidalCompanion::Settings->new();
	}

	require Plugins::TidalCompanion::Swap;
	Plugins::TidalCompanion::Swap->init();

	require Plugins::TidalCompanion::Menus;
	Plugins::TidalCompanion::Menus->init();

	# what's in the library may have changed
	Slim::Control::Request::subscribe(
		sub { Plugins::TidalCompanion::Library->clearCache },
		[['rescan'], ['done']],
	);
	Slim::Control::Request::subscribe(
		sub { Plugins::TidalCompanion::Library->clearCache },
		[['library'], ['changed']],
	);
}

sub getDisplayName { 'PLUGIN_TIDALCOMPANION' }

1;

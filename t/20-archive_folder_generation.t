# $Id: 20-archive_folder_generation.t 18404 2014-05-12 08:28:31Z mg8 $
use strict;
use warnings;
use Test::More tests => 4;
use Test::Exception;
use t::util;

use_ok('npg_pipeline::archive::folder::generation');

my $util = t::util->new();
my $conf_path = $util->conf_path();

$ENV{TEST_DIR} = $util->temp_directory();

local $ENV{NPG_WEBSERVICE_CACHE_DIR} = 't/data';
local $ENV{PATH} = join q[:], q[t/bin], q[t/bin/software/solexa/bin], $ENV{PATH};

{
  $util->remove_staging;
  $util->create_analysis({skip_archive_dir => 1});
  my $afg;
  lives_ok {
    $afg = npg_pipeline::archive::folder::generation->new({
      run_folder => q{123456_IL2_1234},
      runfolder_path => $util->analysis_runfolder_path(),
      conf_path => $conf_path,
      domain => q{test},
      is_indexed => 1,      
    });
  } q{no croak on creation when run_folder provided}; 


  lives_ok { $afg->create_dir(q{staff}); } q{no croak creating archive dir};
  lives_ok { $afg->create_dir(q{staff}); } q{no croak creating archive dir, already exists};
}
1;

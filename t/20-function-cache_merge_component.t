use strict;
use warnings;

use File::Temp;
use Log::Log4perl qw[:levels];
use File::Temp qw[tempdir];
use Test::More tests => 8;
use Test::Exception;
use File::Copy::Recursive qw[dircopy];
use t::util;

my $temp_dir = tempdir(CLEANUP => 1);
Log::Log4perl->easy_init({level  => $INFO,
                          layout => '%d %p %m %n',
                          file   => join(q[/], $temp_dir, 'logfile')});

{
  package TestDB;
  use Moose;

  with 'npg_testing::db';
}

# See README in fixtures for a description of the test data.
my $qc = TestDB->new
  (sqlite_utf8_enabled => 1,
   verbose             => 0)->create_test_db('npg_qc::Schema',
                                             't/data/qc_outcomes/fixtures');

local $ENV{NPG_CACHED_SAMPLESHEET_FILE} =
  't/data/novaseq/180709_A00538_0010_BH3FCMDRXX/' .
  'Data/Intensities/BAM_basecalls_20180805-013153/' .
  'metadata_cache_26291/samplesheet_26291.csv';

my $pkg = 'npg_pipeline::function::cache_merge_component';
use_ok($pkg);

my $runfolder_path = 't/data/novaseq/180709_A00538_0010_BH3FCMDRXX';
my $copy = join q[/], $temp_dir, '180709_A00538_0010_BH3FCMDRXX';
dircopy $runfolder_path, $copy or die 'Failed to copy run folder';
$runfolder_path = $copy;

my $timestamp      = '20180701-123456';

subtest 'local and no_cache_merge_component' => sub {
  plan tests => 7;

  my $cacher = $pkg->new
    (conf_path      => "t/data/release/config/archive_on",
     runfolder_path => $runfolder_path,
     id_run         => 26291,
     timestamp      => $timestamp,
     qc_schema      => $qc,
     local          => 1,
     default_defaults => {}
    );
  ok($cacher->no_cache_merge_component, 'no_cache_merge_component flag is set to true');
  my $ds = $cacher->create;
  is(scalar @{$ds}, 1, 'one definition is returned');
  isa_ok($ds->[0], 'npg_pipeline::function::definition');
  is($ds->[0]->excluded, 1, 'function is excluded');

  $cacher = $pkg->new
    (conf_path      => "t/data/release/config/archive_on",
     runfolder_path => $runfolder_path,
     id_run         => 26291,
     timestamp      => $timestamp,
     qc_schema      => $qc,
     no_cache_merge_component => 1,
     default_defaults => {});
  ok(!$cacher->local, 'local flag is false');
  $ds = $cacher->create;
  is(scalar @{$ds}, 1, 'one definition is returned');
  is($ds->[0]->excluded, 1, 'function is excluded');
};

subtest 'create' => sub {
  plan tests => 4 + (1 + 13) * 4;

  #Tags 7, 8, 1, 11, 2, 5 - preliminary results

  my $cacher;
  lives_ok {
    $cacher = $pkg->new
      (conf_path      => "t/data/release/config/archive_on",
       runfolder_path => $runfolder_path,
       id_run         => 26291,
       timestamp      => $timestamp,
       qc_schema      => $qc,
       default_defaults => {});
  } 'cacher created ok';

  throws_ok {$cacher->create}
    qr/Product 26291\#1, 26291:1:1;26291:2:1 is not Final lib QC value/,
    'error since some results are preliminary';

  my $rs = $qc->resultset('MqcLibraryOutcomeEnt');
  # Make all outcomes final
  while (my $row = $rs->next) {
    if (!$row->has_final_outcome) {
      my $shift = $row->is_undecided ? 1 : 2;
      $row->update({id_mqc_outcome => $row->id_mqc_outcome + $shift});
    }
  }

  my @defs = @{$cacher->create};
  my $num_defs_observed = scalar @defs;
  my $num_defs_expected = 4;
  cmp_ok($num_defs_observed, '==', $num_defs_expected,
         "create returns $num_defs_expected definitions when caching");

  my @archived_rpts;
  foreach my $def (@defs) {
    push @archived_rpts,
      [map { [$_->id_run, $_->position, $_->tag_index] }
         map {$_->components_list} grep {defined} $def->composition];
  }

  is_deeply(\@archived_rpts,
            [
             [[26291, 1, 5], [26291, 2, 5]],
             [[26291, 1, 6], [26291, 2, 6]],
             [[26291, 1,11], [26291, 2,11]],
             [[26291, 1,12], [26291, 2,12]]
                                           ],
            'four undecided final cached')
    or diag explain \@archived_rpts;

  my $cmd_patt = qr|^ln $runfolder_path/.*/archive/plex\d+/.* /tmp/npg_seq_pipeline/cache_merge_component_test/\w{2}/\w{2}/\w{64}$|;

  foreach my $def (@defs) {
    is($def->created_by, $pkg, "created_by is $pkg");
    is($def->identifier, 26291, "identifier is set correctly");

    my $cmd = $def->command;
    my @parts = split / && /, $cmd; # Deconstruct the command
    like(shift @parts, qr|^mkdir -p /tmp/npg_seq_pipeline/cache_merge_component_test/\w{2}/\w{2}/\w{64}$|);
    foreach my $part (@parts) {
      like($part, $cmd_patt, "$cmd matches $cmd_patt");
    }
  }
};

subtest 'abort_on_missing_files' => sub {
  plan tests => 2;

  my $cacher;
  lives_ok {
    $cacher = $pkg->new
      (conf_path      => "t/data/release/config/archive_on",
       runfolder_path => $runfolder_path,
       id_run         => 26291,
       timestamp      => $timestamp,
       qc_schema      => $qc,
       default_defaults => {});
  } 'cacher created ok';

  my $to_move = "$runfolder_path/Data/Intensities/BAM_basecalls_20180805-013153/no_cal/archive/plex12/26291#12.cram";
  my $moved = $to_move . '_moved';
  rename $to_move, $moved or die 'failed to move test file';

  dies_ok {
    $cacher->create;
  } 'aborts okay';

  rename $moved, $to_move or die 'failed to move test file';
};

subtest 'abort_on_missing_lib_qc' => sub {
  plan tests => 2;

  $qc->resultset(q(MqcLibraryOutcomeEnt))->search({})->first->delete;
  my $cacher;
  lives_ok {
    $cacher = $pkg->new
      (conf_path      => "t/data/release/config/archive_on",
       runfolder_path => $runfolder_path,
       id_run         => 26291,
       timestamp      => $timestamp,
       qc_schema      => $qc,
       default_defaults => {});
  } 'cacher created ok';

  dies_ok {
    $cacher->create;
  } 'aborts okay';
};

subtest 'no_cache_study' => sub {
  plan tests => 2;

  my $cacher = $pkg->new
    (conf_path      => "t/data/release/config/archive_off",
     runfolder_path => $runfolder_path,
     id_run         => 26291,
     timestamp      => $timestamp,
     qc_schema      => $qc,
     default_defaults => {});

  my @defs = @{$cacher->create};
  my $num_defs_observed = scalar @defs;
  my $num_defs_expected = 1;
  cmp_ok($num_defs_observed, '==', $num_defs_expected,
         "create returns $num_defs_expected definitions when not archiving") or
           diag explain \@defs;

  is($defs[0]->composition, undef, 'definition has no composition') or
    diag explain \@defs;
};

subtest 'create_with_failed_lane' => sub {
  plan tests => 3;

  $qc->resultset(q(MqcOutcomeEnt))->search({id_run=>26291, position=>1})->first->toggle_final_outcome(q(fakeuser));
  my $cacher;
  lives_ok {
    $cacher = $pkg->new
      (conf_path      => "t/data/release/config/archive_on",
       runfolder_path => $runfolder_path,
       id_run         => 26291,
       timestamp      => $timestamp,
       qc_schema      => $qc,
       default_defaults => {});
  } 'cacher created ok';

  my @defs = @{$cacher->create};
  my $num_defs_observed = scalar @defs;
  my $num_defs_expected = 1; # single "excluded"
  cmp_ok($num_defs_observed, '==', $num_defs_expected,
         "create returns $num_defs_expected definitions when caching");
  ok($defs[0] && $defs[0]->excluded, "excluded")
};

subtest 'abort_on_missing_seq_qc' => sub {
  plan tests => 2;

  $qc->resultset(q(MqcOutcomeEnt))->search({id_run=>26291, position=>1})->first->delete;
  my $cacher;
  lives_ok {
    $cacher = $pkg->new
      (conf_path      => "t/data/release/config/archive_on",
       runfolder_path => $runfolder_path,
       id_run         => 26291,
       timestamp      => $timestamp,
       qc_schema      => $qc,
       default_defaults => {});
  } 'cacher created ok';

  dies_ok {
    $cacher->create;
  } 'aborts okay';
};


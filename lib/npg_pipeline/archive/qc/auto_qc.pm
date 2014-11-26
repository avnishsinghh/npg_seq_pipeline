#############
# $Id: auto_qc.pm 18687 2014-10-20 13:47:30Z mg8 $
# Created By: ajb
# Last Maintained By: $Author: mg8 $
# Created On: 2009-09-01
# Last Changed On: $Date: 2014-10-20 14:47:30 +0100 (Mon, 20 Oct 2014) $
# $HeadURL: svn+ssh://svn.internal.sanger.ac.uk/repos/svn/new-pipeline-dev/npg-pipeline/trunk/lib/npg_pipeline/archive/qc/auto_qc.pm $

package npg_pipeline::archive::qc::auto_qc;
use Moose;
use Carp;
use English qw{-no_match_vars};
use Readonly; Readonly::Scalar our $VERSION => do { my ($r) = q$LastChangedRevision: 18687 $ =~ /(\d+)/mxs; $r; };
use File::Spec;

extends qw{npg_pipeline::base};

sub submit_to_lsf {
  my ($self, $arg_refs) = @_;
  my $job_sub = $self->_generate_bsub_command($arg_refs);
  my $job_id = $self->submit_bsub_command($job_sub);
  return ($job_id);
}

# private methods

sub _generate_bsub_command {
  my ($self, $arg_refs) = @_;

  my $required_job_completion = $arg_refs->{required_job_completion};
  my $timestamp = $self->timestamp();

  my $job_name = q{autoqc_loader_} . $self->id_run() . q{_} . $timestamp;

  my $location_of_logs = $self->make_log_dir( $self->recalibrated_path() );
  my @qc_paths = ($self->qc_path());

  if ($self->is_indexed) {
    foreach my $position ( $self->positions() ) {
      my $path = $self->lane_qc_path($position);
      if (-e $path) {
  	push @qc_paths, $path;
      }
    }
  }

  my $bsub_command = q{bsub -q } . $self->lsf_queue() . qq{ $required_job_completion -J $job_name };
  $bsub_command .=  ( $self->fs_resource_string( {
    counter_slots_per_job => 1,
  } ) ) . q{ };
  $bsub_command .=  q{-o } . File::Spec->catfile( $location_of_logs, $job_name . q{.out } );
  $bsub_command .=  q{'};
  $bsub_command .=  $self->external_script_names_conf()->{auto_qc_loader};
  $bsub_command .=  q{ --id_run=} . $self->id_run();

  for my $path (@qc_paths) {
    $bsub_command .=  qq{ --path=$path};
  }

  $bsub_command .=  q{'};

  if ($self->verbose()) {
    $self->log($bsub_command);
  }

  return $bsub_command;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
__END__

=head1 NAME

npg_pipeline::archive::qc::auto_qc

=head1 VERSION

$LastChangedRevision: 18687 $

=head1 SYNOPSIS

  my $aaq = npg_pipeline::archive::qc::auto_qc->new({
    run_folder => <run_folder>,
  });

=head1 DESCRIPTION

=head1 SUBROUTINES/METHODS

=head2 submit_to_lsf - handles calling out to create the bsub command and submits it, returning the job ids

  my @job_ids = $aaq->submit_to_lsf({
    required_job_completion => <lsf job requirement string>,
    timestamp => <timestamp string>,
  });

=head1 DIAGNOSTICS

=head1 CONFIGURATION AND ENVIRONMENT

=head1 DEPENDENCIES

=over

=item Moose

=item Carp

=item English -no_match_vars

=item Readonly

=back

=head1 INCOMPATIBILITIES

=head1 BUGS AND LIMITATIONS

=head1 AUTHOR

$Author: mg8 $

=head1 LICENSE AND COPYRIGHT

Copyright (C) 2010 GRL, by Andy Brown (ajb@sanger.ac.uk)

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.

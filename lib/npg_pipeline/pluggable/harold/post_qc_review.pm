#############
# $Id: post_qc_review.pm 18296 2014-04-03 11:26:45Z mg8 $
# Created By: ajb
# Last Maintained By: $Author: mg8 $
# Created On: 2009-11-05
# Last Changed On: $Date: 2014-04-03 12:26:45 +0100 (Thu, 03 Apr 2014) $
# $HeadURL: svn+ssh://svn.internal.sanger.ac.uk/repos/svn/new-pipeline-dev/npg-pipeline/trunk/lib/npg_pipeline/pluggable/harold/post_qc_review.pm $

package npg_pipeline::pluggable::harold::post_qc_review;
use Moose;
use Carp;
use English qw{-no_match_vars};
use File::Spec;
use Readonly; Readonly::Scalar our $VERSION => do { my ($r) = q$LastChangedRevision: 18296 $ =~ /(\d+)/mxs; $r; };

use npg_pipeline::cache;
extends qw{npg_pipeline::pluggable::harold};

=head1 NAME

npg_pipeline::pluggable::harold::post_qc_review

=head1 VERSION

$LastChangedRevision: 18296 $

=head1 SYNOPSIS

  my $oPostQCReview = npg_pipeline::pluggable::harold::post_qc_review->new();

=head1 DESCRIPTION

Pluggable pipeline module for the post_qc_review pipeline

=head1 SUBROUTINES/METHODS

=head2 archive_to_irods

upload all archival files to irods

=cut

sub archive_to_irods {
  my ($self, @args) = @_;
  if ($self->no_irods_archival) {
    $self->log(q{Archival to iRODS is switched off.});
    return ();
  }
  my $required_job_completion = shift @args;
  my $ats = $self->new_with_cloned_attributes(q{npg_pipeline::archive::file::to_irods});
  my @job_ids = $ats->submit_to_lsf({
    required_job_completion => $required_job_completion,
  });
  return @job_ids;
}

=head2 upload_illumina_analysis_to_qc_database

upload illumina analysis qc data 

=cut

sub upload_illumina_analysis_to_qc_database {
  my ($self, @args) = @_;
  my $required_job_completion = shift @args;
  my $aia = $self->new_with_cloned_attributes(q{npg_pipeline::archive::qc::illumina_analysis});
  my @job_ids = $aia->submit_to_lsf({
    required_job_completion => $required_job_completion,
  });
  return @job_ids;
}

=head2 upload_fastqcheck_to_qc_database

upload fastqcheck files to teh qc database

=cut

sub upload_fastqcheck_to_qc_database {
  my ($self, @args) = @_;
  my $required_job_completion = shift @args;
  my $aia = $self->new_with_cloned_attributes(q{npg_pipeline::archive::qc::fastqcheck_loader});
  my @job_ids = $aia->submit_to_lsf({
    required_job_completion => $required_job_completion,
  });
  return @job_ids;
}

=head2 upload_auto_qc_to_qc_database

upload internal auto_qc data

=cut

sub upload_auto_qc_to_qc_database {
  my ($self, @args) = @_;
  my $required_job_completion = shift @args;
  my $aaq = $self->new_with_cloned_attributes(q{npg_pipeline::archive::qc::auto_qc});
  my @job_ids = $aaq->submit_to_lsf({
    required_job_completion => $required_job_completion,
  });
  return @job_ids;
}

=head2 update_warehouse

Updates run data in the npg tables of the warehouse.

=cut
sub update_warehouse {
  my ($self, @args) = @_;
  if ($self->no_warehouse_update) {
    $self->log(q{Updates to warehouse is switched off.});
    return ();
  }
  my $required_job_completion = shift @args;
  my $command = $self->_update_warehouse_command($required_job_completion);
  return $self->submit_bsub_command($command);
}

sub _update_warehouse_command {
  my ($self, $required_job_completion) = @_;

  my $id_run = $self->id_run;
  my $command = join q[ ], map {q[unset ] . $_ . q[;]} npg_pipeline::cache->env_vars;
  $command .= qq{ warehouse_loader --id_run $id_run};
  my $job_name = join q{_}, q{whupdate}, $id_run, $self->pipeline_name;
  my $out = join q{_}, $job_name, $self->timestamp . q{.out};
  $out =  File::Spec->catfile($self->make_log_dir( $self->recalibrated_path()), $out );
  (my $name) = __PACKAGE__ =~ /(\w+)$/smx;
  $name = lc $name;
  if ($self->pipeline_name eq $name) {
    $out =~ s/\/analysis\//\/outgoing\//smx; #the job is run after the runfolder is moved to outgoing
  }
  return q{bsub -q } . $self->lsf_queue() . qq{ $required_job_completion -J $job_name -o $out '$command'};
}

=head2 copy_interop_files_to_irods

Copy the copy_interop_files files to iRODS

=cut
sub copy_interop_files_to_irods
{
  my ($self, @args) = @_;
  my $required_job_completion = shift @args;
  my $command = $self->_interop_command($required_job_completion);
  return $self->submit_bsub_command($command);
}

sub _interop_command
{
  my ($self, $required_job_completion) = @_;
  my $id_run = $self->id_run;
  my $command = "irods_interop_loader.pl --id_run $id_run --runfolder_path ".$self->runfolder_path();
  my $job_name = 'interop_' . $id_run . '_' . $self->pipeline_name;
  my $out = join q{_}, $job_name, $self->timestamp . q{.out};
  $out =  File::Spec->catfile($self->make_log_dir( $self->runfolder_path()), $out );
  my $resources = $self->fs_resource_string( {
                   counter_slots_per_job => 1,
                   seq_irods             => $self->general_values_conf()->{default_lsf_irods_resource},
                                             } );
  return q{bsub -q } . $self->lsf_queue() . qq{ $required_job_completion -J $job_name $resources -o $out '$command'};
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
__END__

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

package npg_pipeline::executor;

use Moose;
use MooseX::StrictConstructor;
use namespace::autoclean;
use Graph::Directed;
use File::Slurp;
use File::Basename;
use List::MoreUtils qw/any firstidx/;
use Readonly;

use npg_tracking::util::types;
use npg_pipeline::runfolder_scaffold;

with qw{ WTSI::DNAP::Utilities::Loggable };

our $VERSION = '0';

Readonly::Scalar my $VERTEX_NUM_DEFINITIONS_ATTR_NAME => q{num_definitions};
Readonly::Scalar my $VERTEX_JOB_PRIORITY_ATTR_NAME    => q{job_priority};
Readonly::Scalar my $JOB_PRIORITY_INCREMENT           => 10;
Readonly::Scalar my $P4STAGE1_FUNCTION_NAME           => q{p4_stage1_analysis};
Readonly::Scalar my $QC_COMPLETE_FUNCTION_NAME        => q{run_qc_complete};

=head1 NAME

npg_pipeline::executor

=head1 SYNOPSIS

  package npg_pipeline::executor::exotic;
  use Moose;
  extends 'pg_pipeline::executor';

  override 'execute' => sub {
    my $self = shift;
    $self->info('Child implementation');
  };
  1;

  package main;
  use Graph::Directed;
  use npg_pipeline::function::definition;

  my $g =  Graph::Directed->new();
  $g->add_edge('node_one', 'node_two');

  my $d = npg_pipeline::function::definition->new(
    created_by   => 'module',
    created_on   => 'June 25th',
    job_name     => 'name',
    identifier   => 2345,
    command      => '/bin/true',
    log_file_dir => '/tmp/dir'
  );

  my $e1 = npg_pipeline::executor::exotic->new(
    function_graph          => $g,
    function_definitions    => {node_one => [$d]},
    commands4jobs_file_path => '/tmp/path'
  );
  $e1->execute();

  my $e2 = npg_pipeline::executor::exotic->new(
    function_graph       => $g,
    function_definitions => {node_one => [$d],
    analysis_path        => '/tmp/analysis'
  );
  print $e2->commands4jobs_file_path();
  $e2->execute();

=head1 DESCRIPTION

Submission of function definition for execution - parent object.
Child classes should implement 'execute' method.

=cut

=head1 SUBROUTINES/METHODS

=cut

##################################################################
################## Public attributes #############################
##################################################################

=head2 analysis_path

=cut

has 'analysis_path' => (
  isa       => 'NpgTrackingDirectory',
  is        => 'ro',
  required  => 0,
  predicate => 'has_analysis_path',
);

=head2 function_graph

=cut

has 'function_graph' => (
  is       => 'ro',
  isa      => 'Graph::Directed',
  required => 1,
);

=head2 function_definitions

=cut

has 'function_definitions' => (
  is       => 'ro',
  isa      => 'HashRef',
  required => 1,
);

=head2 commands4jobs

=cut

has 'commands4jobs' => (
  is      => 'ro',
  isa     => 'HashRef',
  default => sub {return {};},
);

=head2 commands4jobs_file_path

=cut

has 'commands4jobs_file_path' => (
  is         => 'ro',
  isa        => 'Str',
  lazy_build => 1,
);
sub _build_commands4jobs_file_path {
  my $self = shift;

  if (!$self->has_analysis_path()) {
    $self->logcroak(q{analysis_path attribute is not set});
  }
  my @functions = keys %{$self->function_definitions()};
  if (!@functions) {
    $self->logcroak(q{Definition hash is empty});
  }
  my $d = $self->function_definitions()->{$functions[0]}->[0];
  if (!$d) {
    $self->logcroak(q{Empty definition array for } . $functions[0]);
  }
  my $name = join q[_], 'commands4jobs', $d->identifier(), $d->created_on();
  return join q[/], $self->analysis_path(), $name;
}

=head2 function_graph4jobs

The graph of functions that have to be executed. The same graph as in
the 'function_graph' attribute, but the functions that have to be skipped
are excluded.

Each node of this graph has 'num_definitions' attribute set.

=cut

has 'function_graph4jobs' => (
  is         => 'ro',
  isa        => 'Graph::Directed',
  init_arg   => undef,
  required   => 0,
  lazy_build => 1,
);
sub _build_function_graph4jobs {
  my $self = shift;

  my $graph = Graph::Directed->new();

  my $g = $self->function_graph();
  my @nodes = $g->topological_sort();
  if (!@nodes) {
    $self->logcroak('Empty function graph');
  }

  foreach my $function (@nodes) {

    if (!exists $self->function_definitions()->{$function}) {
      $self->logcroak(qq{Function $function is not defined});
    }
    my $definitions = $self->function_definitions()->{$function};
    if (!$definitions) {
      $self->logcroak(qq{No definition array for function $function});
    }
    if(!@{$definitions}) {
      $self->logcroak(qq{Definition array for function $function is empty});
    }

    my $num_definitions = scalar @{$definitions};

    if ($num_definitions == 1) {
      my $d = $definitions->[0];
      if ($d->excluded) {
        $self->info(qq{***** Function $function is excluded});
        next;
      }
    }

    #####
    # Find all closest ancestors that represent functions that will be
    # submitted for execution, bypassing the skipped functions.
    #
    # For each returned predecessor create an edge from the predecessor function
    # to this function. Adding an edge implicitly add its vertices. Adding
    # a vertex is by default idempotent. Setting a vertex attribute creates
    # a vertex if it does not already exists.
    #
    my @predecessors = predecessors($g, $function, $VERTEX_NUM_DEFINITIONS_ATTR_NAME);

    if (@predecessors || $g->is_source_vertex($function)) {
      foreach my $gr (($g, $graph)) {
        $gr->set_vertex_attribute($function,
                                  $VERTEX_NUM_DEFINITIONS_ATTR_NAME,
                                  $num_definitions);
      }
      foreach my $p (@predecessors) {
        $graph->add_edge($p, $function);
      }
    }
  }

  if (!$graph->vertices()) {
    $self->logcroak('New function graph is empty');
  }

  if ($self->can('job_priority')) {
    my @pre = $graph->all_predecessors($P4STAGE1_FUNCTION_NAME);
    push @pre, $P4STAGE1_FUNCTION_NAME;
    my $priority = $self->job_priority ? $self->job_priority : 0;
    my $higher_priority = $priority + $JOB_PRIORITY_INCREMENT;
    foreach my $n ($graph->vertices()) {
      my $p = (any {$_ eq $n } @pre) ? $higher_priority : $priority;
      $self->warn(qq{***** Assigning job priority $p to $n});
      $graph->set_vertex_attribute($n, $VERTEX_JOB_PRIORITY_ATTR_NAME, $p);
    }
  }

  return $graph;
}

##################################################################
############## Public methods ####################################
##################################################################

=head2 execute

Basic implementation that does not do anything. The method should be
implemented by a child class.

=cut

sub execute { return; }

=head2 predecessors

Recursive function. The recursion ends when we either
reach the start point - the vertext that has no predesessors -
or a vertex whose all predesessors have the attribute, the name of
which is given as an argument, set.

Should not be called as a class or instance method.

Returns a list of found predecessors.

  my @predecessor_functions = predecessors($graph,
                                           'qc_insert_size',
                                           'num_definitions');
=cut

sub predecessors {
  my ($g, $function_name, $attr_name) = @_;

  my @predecessors = ();
  foreach my $p (sort $g->predecessors($function_name)) {
    if ($g->has_vertex_attribute($p, $attr_name)) {
      push @predecessors, $p;
    } else {
      push @predecessors, predecessors($g, $p, $attr_name);
    }
  }
  return @predecessors;
}

=head2 dependencies

Returns a list of function's (job's) dependencies that are saved
in graph nodes' attributes given as the second argument;

  my @dependencies = $e->dependencies('qc_insert_size', 'lsf_job_ids');

=cut

sub dependencies {
  my ($self, $function_name, $attr_name) = @_;

  my $g = $self->function_graph4jobs();
  my @dependencies = ();
  foreach my $p ($g->predecessors($function_name)) {
    if (!$g->has_vertex_attribute($p, $attr_name)) {
      $self->logcroak(qq{$attr_name attribute does not exist for $p})
    }
    my $attr_value = $g->get_vertex_attribute($p, $attr_name);
    if (!$attr_value) {
      $self->logcroak(qq{Value of the $attr_name is not defined for $p});
    }
    push @dependencies, $attr_value;
  }

  return @dependencies;
}

=head2 save_commands4jobs

Saves a list of commands to a file defined by the commands4jobs_file_path
attribute.

=cut

sub save_commands4jobs {
  my ($self, @commands) = @_;

  if (!@commands) {
    $self->logcroak(q[List of commands cannot be empty]);
  }
  my $file = $self->commands4jobs_file_path();
  $self->info();
  $self->info(qq[***** Writing commands for jobs to ${file}]);
  return write_file($file, map { $_ . qq[\n] } @commands);
}

=head2 log_dir4function

Ensures a log directory for the argument function exists and return its path.

=cut

sub log_dir4function {
  my ($self, $function_name) = @_;

  my $log_dir_parent = $self->has_analysis_path()
                       ? $self->analysis_path()
                       : dirname($self->commands4jobs_file_path());

  my $output = npg_pipeline::runfolder_scaffold
               ->make_log_dir4names($log_dir_parent, $function_name);
  my @errors = @{$output->{'errors'}};
  my $dir;
  if (@errors) {
    $self->logcroak(join qq[\n], @errors);
  } else {
    $dir = $output->{'dirs'}->[0];
    $self->info(qq[Created log directory $dir for function $function_name]);
  }

  return $dir;
}

=head2 future_path_is_in_outgoing

The archival pipeline normally starts in the analysis directory. Once
the run_qc_complete job has been run, the staging daemon moves the
runfolder to the outgoing directory. The paths used by any job that
runs after run_qc_complete have to be adjusted.

This method returns a boolean value which, if true, means that the
paths used by the job have to use the outgoing directory.

=cut

sub future_path_is_in_outgoing {
  my ($self, $function_name) = @_;

  $function_name or $self->logcroak('Function name is required');

  my $path_is_in_outgoing = 0;
  my @nodes = $self->function_graph4jobs->topological_sort();

  my $function_index = firstidx { $_ eq $function_name } @nodes;
  if ($function_index < 0) {
    $self->logcroak("'$function_name' not found in the graph");
  }

  my $index = firstidx { $_ eq $QC_COMPLETE_FUNCTION_NAME } @nodes;
  if ($index >= 0 && $function_index > $index) {
    $path_is_in_outgoing = 1;
  }
  return $path_is_in_outgoing;
}


__PACKAGE__->meta->make_immutable;

1;

__END__

=head1 DIAGNOSTICS

=head1 CONFIGURATION AND ENVIRONMENT

=head1 DEPENDENCIES

=over

=item Moose

=item MooseX::StrictConstructor

=item namespace::autoclean

=item Graph::Directed

=item File::Slurp

=item File::Basename

=item List::MoreUtils

=item Readonly

=item WTSI::DNAP::Utilities::Loggable

=back

=head1 INCOMPATIBILITIES

=head1 BUGS AND LIMITATIONS

=head1 AUTHOR

=over

=item Marina Gourtovaia

=back

=head1 LICENSE AND COPYRIGHT

Copyright (C) 2018 Genome Research Ltd.

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

package AI::DecisionTree;
BEGIN {
  $VERSION = '0.05';
  @ISA = qw(DynaLoader);
}

use strict;
use AI::DecisionTree::Instance;
use Carp;
use vars qw($VERSION @ISA);


sub new {
  my $package = shift;
  return bless {
		noise_mode => 'fatal',
		prune => 1,
		@_,
		nodes => 0,
		instances => [],
	       }, $package;
}

sub nodes      { $_[0]->{nodes} }
sub noise_mode { $_[0]->{noise_mode} }

sub add_instance {
  my ($self, %args) = @_;
  croak "Missing 'attributes' parameter" unless $args{attributes};
  croak "Missing 'result' parameter" unless defined $args{result};
  
  my @attributes;
  while (my ($k, $v) = each %{$args{attributes}}) {
    $attributes[ _hlookup($self->{attributes}, $k) ] = _hlookup($self->{attribute_values}{$k}, $v);
  }
  $_ ||= 0 foreach @attributes;
  
  push @{$self->{instances}}, AI::DecisionTree::Instance->new(\@attributes, _hlookup($self->{results}, $args{result}));
}

sub _hlookup {
  $_[0] ||= {}; # Autovivify as a hash
  my ($hash, $key) = @_;
  unless (exists $hash->{$key}) {
    $hash->{$key} = 1 + keys %$hash;
  }
  return $hash->{$key};
}

sub train {
  my ($self) = @_;
  croak "Cannot train the same tree twice" if $self->{tree};
  croak "Must add training instances before calling train()" unless @{ $self->{instances} };

  my $h = $self->{results};
  $self->{results_reverse} = [ undef, sort {$h->{$a} <=> $h->{$b}} keys %$h ];
  
  foreach my $attr (keys %{$self->{attribute_values}}) {
    my $h = $self->{attribute_values}{$attr};
    $self->{attribute_values_reverse}{$attr} = [ undef, sort {$h->{$a} <=> $h->{$b}} keys %$h ];
  }

  $self->{tree} = $self->_expand_node( instances => $self->{instances} );
  delete $self->{instances};

  $self->prune_tree if $self->{prune};
  delete @{$self}{qw(attribute_values attribute_values_reverse results results_reverse)};
  return 1;
}

# Each node contains:
#  { split_on => $attr_name,
#    children => { $attr_value1 => $node1,
#                  $attr_value2 => $node2, ... }
#  }
# or
#  { result => $result }

sub _expand_node {
  my ($self, %args) = @_;
  my $instances = $args{instances};
  
  $self->{nodes}++;

  my %results;
  $results{$self->_result($_)}++ foreach @$instances;
  my @results = map {$_,$results{$_}} sort {$results{$b} <=> $results{$a}} keys %results;
  my %node = ( distribution => \@results, instances => scalar @$instances );

  if (keys(%results) == 1) {
    # All these instances have the same result - make this node a leaf
    $node{result} = $self->_result($instances->[0]);
    return \%node;
  }

  
  # Multiple values are present - find the best predictor attribute and split on it
  my $best_attr = $self->best_attr($instances);

  croak "Inconsistent data, can't build tree with noise_mode='fatal'"
    if $self->{noise_mode} eq 'fatal' and !defined $best_attr;

  unless (defined $best_attr) {
    # Pick the most frequent result for this leaf
    $node{result} = (sort {$results{$b} <=> $results{$a}} keys %results)[0];
    return \%node;
  }
  
  $node{split_on} = $best_attr;
  
  my %split;
  foreach my $i (@$instances) {
    my $v = $self->_delete_value($i, $best_attr);
    push @{$split{ defined($v) ? $v : '<undef>' }}, $i;
  }
  die ("Something's wrong: attribute '$best_attr' didn't split ",
       scalar @$instances, " instances into multiple buckets (@{[ keys %split ]})")
    unless keys %split > 1;

  foreach my $value (keys %split) {
    $node{children}{$value} = $self->_expand_node( instances => $split{$value} );
  }
  
  return \%node;
}

sub best_attr {
  my ($self, $instances) = @_;

  # 0 is a perfect score, entropy(#instances) is the worst possible score
  
  my ($best_score, $best_attr) = (@$instances * $self->entropy( map $_->result_int, @$instances ), undef);
  my $all_attr = $self->{attributes};
  foreach my $attr (keys %$all_attr) {

    # %tallies is correlation between each attr value and result
    # %total is number of instances with each attr value
    my (%totals, %tallies);
    my $num_undef = AI::DecisionTree::Instance::->tally($instances, \%tallies, \%totals, $all_attr->{$attr});
    next unless keys %totals; # Make sure at least one instance defines this attribute
    
    my $score = 0;
    while (my ($opt, $vals) = each %tallies) {
      $score += $totals{$opt} * $self->entropy2( $vals, $totals{$opt} );
    }

    ($best_attr, $best_score) = ($attr, $score) if $score < $best_score;
  }
  
  return $best_attr;
}

sub entropy2 {
  shift;
  my ($counts, $total) = @_;

  # Entropy is defined with log base 2 - we just divide by log(2) at the end to adjust.
  my $sum = 0;
  $sum += $_ * log($_) foreach values %$counts;
  return +(log($total) - $sum/$total)/log(2);
}

sub entropy {
  shift;

  my %count;
  $count{$_}++ foreach @_;

  # Entropy is defined with log base 2 - we just divide by log(2) at the end to adjust.
  my $sum = 0;
  $sum += $_ * log($_) foreach values %count;
  return +(log(@_) - $sum/@_)/log(2);
}

sub prune_tree {
  my $self = shift;

  # We use a minimum-description-length approach.  We calculate the
  # score of each node:
  #  n = number of nodes below
  #  r = number of results (categories) in the entire tree
  #  i = number of instances in the entire tree
  #  e = number of errors below this node

  # Hypothesis description length (MML):
  #  describe tree: number of nodes + number of edges
  #  describe exceptions: num_exceptions * log2(total_num_instances) * log2(total_num_results)
  
  my $r = keys %{ $self->{results} };
  my $i = $self->{tree}{instances};
  my $exception_cost = log($r) * log($i) / log(2)**2;

  # Pruning can turn a branch into a leaf
  my $maybe_prune = sub {
    my ($self, $node) = @_;
    return unless $node->{children};  # Can't prune leaves

    my $nodes_below = $self->nodes_below($node);
    my $tree_cost = 2 * $nodes_below - 1;  # $edges_below == $nodes_below - 1
    
    my $exceptions = $self->exceptions( $node );
    my $simple_rule_exceptions = $node->{instances} - $node->{distribution}[1];

    my $score = -$nodes_below - ($exceptions - $simple_rule_exceptions) * $exception_cost;
    #warn "Score = $score = -$nodes_below - ($exceptions - $simple_rule_exceptions) * $exception_cost\n";
    if ($score < 0) {
      delete @{$node}{'children', 'split_on', 'exceptions', 'nodes_below'};
      $node->{result} = $node->{distribution}[0];
      # XXX I'm not cleaning up 'exceptions' or 'nodes_below' keys up the tree
    }
  };

  $self->_traverse($maybe_prune);
}

sub exceptions {
  my ($self, $node) = @_;
  return $node->{exceptions} if exists $node->{exeptions};
  
  my $count = 0;
  if ( exists $node->{result} ) {
    $count = $node->{instances} - $node->{distribution}[1];
  } else {
    foreach my $child ( values %{$node->{children}} ) {
      $count += $self->exceptions($child);
    }
  }
  
  return $node->{exceptions} = $count;
}

sub nodes_below {
  my ($self, $node) = @_;
  return $node->{nodes_below} if exists $node->{nodes_below};

  my $count = 0;
  $self->_traverse( sub {$count++}, $node );

  return $node->{nodes_below} = $count - 1;
}

# This is *not* for external use, I may change it.
sub _traverse {
  my ($self, $callback, $node, $parent, $node_name) = @_;
  $node ||= $self->{tree};
  
  ref($callback) ? $callback->($self, $node, $parent, $node_name) : $self->$callback($node, $parent, $node_name);
  
  return unless $node->{children};
  foreach my $child ( keys %{$node->{children}} ) {
    $self->_traverse($callback, $node->{children}{$child}, $node, $child);
  }
}

sub get_result {
  my ($self, %args) = @_;
  croak "Missing 'attributes' parameter" unless $args{attributes};
  my $a = $args{attributes};

  $self->train unless $self->{tree};
  my $tree = $self->{tree};
  my $count = 0;
  
  while (1) {
    if (exists $tree->{result}) {
      my $r = $tree->{result};
      return ($r, $tree->{distribution}[1] / $tree->{instances}, $count) if wantarray;
      return $r;
    }
    $count++;

    my $instance_val = exists $a->{$tree->{split_on}} ? $a->{$tree->{split_on}} : '<undef>';
    $tree = $tree->{children}{ $instance_val }
      or return undef;
  }
}

sub as_graphviz {
  my $self = shift;
  require GraphViz;
  my $g = new GraphViz;

  my $id = 1;
  my $add_edge = sub {
    my ($self, $node, $parent, $node_name) = @_;
    # We use stringified reference names for node names, as a convenient hack.

    $g->add_node( "$node",
		  label => $node->{split_on} || $node->{result},
		  shape => ($node->{split_on} ? 'ellipse' : 'box'),
		);
    $g->add_edge( "$parent" => "$node",
		  label => $node_name,
		) if $parent;
  };

  $self->_traverse( $add_edge );
  return $g;
}

sub rule_tree {
  my $self = shift;
  my ($tree) = @_ ? @_ : $self->{tree};
  
  # build tree:
  # [ question, { results => [ question, { ... } ] } ]
  
  return $tree->{result} if exists $tree->{result};
  
  return [
	  $tree->{split_on}, {
			      map { $_ => $self->rule_tree($tree->{children}{$_}) } keys %{$tree->{children}},
			     }
	 ];
}

sub rule_statements {
  my $self = shift;
  my ($stmt, $tree) = @_ ? @_ : ('', $self->{tree});
  return("$stmt -> '$tree->{result}'") if exists $tree->{result};
  
  my @out;
  my $prefix = $stmt ? "$stmt and" : "if";
  foreach my $val (keys %{$tree->{children}}) {
    push @out, $self->rule_statements("$prefix $tree->{split_on}='$val'", $tree->{children}{$val});
  }
  return @out;
}

### Some instance accessor stuff:

sub _result {
  my ($self, $instance) = @_;
  my $int = $instance->result_int;
  return $self->{results_reverse}[$int];
}

sub _delete_value {
  my ($self, $instance, $attr) = @_;
  my $val = $self->_value($instance, $attr);
  return unless defined $val;
  
  $instance->set_value($self->{attributes}{$attr}, 0);
  return $val;
}

sub _value {
  my ($self, $instance, $attr) = @_;
  return unless exists $self->{attributes}{$attr};
  my $val_int = $instance->value_int($self->{attributes}{$attr});
  return $self->{attribute_values_reverse}{$attr}[$val_int];
}



1;
__END__

=head1 NAME

AI::DecisionTree - Automatically Learns Decision Trees

=head1 SYNOPSIS

  use AI::DecisionTree;
  my $dtree = new AI::DecisionTree;
  
  # A set of training data for deciding whether to play tennis
  $dtree->add_instance
    (attributes => {outlook     => 'sunny',
                    temperature => 'hot',
                    humidity    => 'high'},
     result => 'no');
  
  $dtree->add_instance
    (attributes => {outlook     => 'overcast',
                    temperature => 'hot',
                    humidity    => 'normal'},
     result => 'yes');

  ... repeat for several more instances, then:
  $dtree->train;
  
  # Find results for unseen instances
  my $result = $dtree->get_result
    (attributes => {outlook     => 'sunny',
                    temperature => 'hot',
                    humidity    => 'normal'});

=head1 DESCRIPTION

The C<AI::DecisionTree> module automatically creates so-called
"decision trees" to explain a set of training data.  A decision tree
is a kind of categorizer that use a flowchart-like process for
categorizing new instances.  For instance, a learned decision tree
might look like the following, which classifies for the concept "play
tennis":

                   OUTLOOK
                   /  |  \
                  /   |   \
                 /    |    \
           sunny/  overcast \rainy
               /      |      \
          HUMIDITY    |       WIND
          /  \       *no*     /  \
         /    \              /    \
    high/      \normal      /      \
       /        \    strong/        \weak
     *no*      *yes*      /          \
                        *no*        *yes*

(This example, and the inspiration for the C<AI::DecisionTree> module,
come directly from Tom Mitchell's excellent book "Machine Learning",
available from McGraw Hill.)

A decision tree like this one can be learned from training data, and
then applied to previously unseen data to obtain results that are
consistent with the training data.

The usual goal of a decision tree is to somehow encapsulate the
training data in the smallest possible tree.  This is motivated by an
"Occam's Razor" philosophy, in which the simplest possible explanation
for a set of phenomena should be preferred over other explanations.
Also, small trees will make decisions faster than large trees, and
they are much easier for a human to look at and understand.  One of
the biggest reasons for using a decision tree instead of many other
machine learning techniques is that a decision tree is a much more
scrutable decision maker than, say, a neural network.

The current implementation of this module uses an extremely simple
method for creating the decision tree based on the training instances.
It uses an Information Gain metric (based on expected reduction in
entropy) to select the "most informative" attribute at each node in
the tree.  This is essentially the ID3 algorithm, developed by
J. R. Quinlan in 1986.  The idea is that the attribute with the
highest Information Gain will (probably) be the best attribute to
split the tree on at each point if we're interested in making small
trees.

=head1 METHODS

=head2 Building and Querying the Tree

=over 4

=item new()

=item new(noise_mode => 'pick_best')

Creates a new decision tree object and returns it.

Accepts a parameter, C<noise_mode>, which controls the behavior of the
C<train()> method when "noisy" data is encountered.  Here "noisy"
means that two or more training instances contradict each other, such
that they have identical attributes but different results.

If C<noise_mode> is set to C<fatal> (the default), the C<train()>
method will throw an exception (die).  If C<noise_mode> is set to
C<pick_best>, the most frequent result at each noisy node will be
selected.

C<new()> also accepts a boolean C<prune> parameter which specifies
whether the tree should be pruned after training.  This is usually a
good idea, so the default is to prune.  Currently we prune using a
simple minimum-description-length criterion.

=item add_instance(attributes => \%hash, result => $string)

Adds a training instance to the set of instances which will be used to
form the tree.  An C<attributes> parameter specifies a hash of
attribute-value pairs for the instance, and a C<result> parameter
specifies the result.

=item train()

Builds the decision tree from the list of training instances.

=item get_result(attributes => \%hash)

Returns the most likely result (from the set of all results given to
C<add_instance()>) for the set of attribute values given.  An
C<attributes> parameter specifies a hash of attribute-value pairs for
the instance.  If the decision tree doesn't have enough information to
find a result, it will return C<undef>.

=back

=head2 Tree Introspection

=over 4

=item nodes()

Returns the number of nodes in the trained decision tree.

=item rule_tree()

Returns a data structure representing the decision tree.  For 
instance, for the tree diagram above, the following data structure 
is returned:

 [ 'outlook', {
     'rain' => [ 'wind', {
         'strong' => 'no',
         'weak' => 'yes',
     } ],
     'sunny' => [ 'humidity', {
         'normal' => 'yes',
         'high' => 'no',
     } ],
     'overcast' => 'yes',
 } ]

This is slightly remniscent of how XML::Parser returns the parsed 
XML tree.

Note that while the ordering in the hashes is unpredictable, the 
nesting is in the order in which the criteria will be checked at 
decision-making time.

=item rule_statements()

Returns a list of strings that describe the tree in rule-form.  For
instance, for the tree diagram above, the following list would be
returned (though not necessarily in this order - the order is
unpredictable):

  if outlook='rain' and wind='strong' -> 'no'
  if outlook='rain' and wind='weak' -> 'yes'
  if outlook='sunny' and humidity='normal' -> 'yes'
  if outlook='sunny' and humidity='high' -> 'no'
  if outlook='overcast' -> 'yes'

This can be helpful for scrutinizing the structure of a tree.

Note that while the order of the rules is unpredictable, the order of
criteria within each rule reflects the order in which the criteria
will be checked at decision-making time.

=back

=head1 LIMITATIONS

A few limitations exist in the current version.  All of them could be
removed in future versions - especially with your help. =)

=over 4

=item No continuous attributes

In the current implementation, only discrete-valued attributes are
supported.  This means that an attribute like "temperature" can have
values like "cool", "medium", and "hot", but using actual temperatures
like 87 or 62.3 is not going to work.  This is because the values
would split the data too finely - the tree-building process would
probably think that it could make all its decisions based on the exact
temperature value alone, ignoring all other attributes, because each
temperature would have only been seen once in the training data.

The usual way to deal with this problem is for the tree-building
process to figure out how to place the continuous attribute values
into a set of bins (like "cool", "medium", and "hot") and then build
the tree based on these bin values.  Future versions of
C<AI::DecisionTree> may provide support for this.  For now, you have
to do it yourself.

=back

=head1 TO DO

All the stuff in the LIMITATIONS section.  Also, revisit the pruning
algorithm to see how it can be improved.

=head1 AUTHOR

Ken Williams, ken@mathforum.org

=head1 SEE ALSO

Mitchell, Tom (1997).  Machine Learning.  McGraw-Hill. pp 52-80.

Quinlan, J. R. (1986).  Induction of decision trees.  Machine
Learning, 1(1), pp 81-106.

L<perl>.

=cut

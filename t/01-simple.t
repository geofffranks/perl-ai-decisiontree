# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl test.pl'

#########################

use Test;
BEGIN { plan tests => 16 };
use AI::DecisionTree;
ok(1); # If we made it this far, we're ok.

#########################

my @attributes = qw(outlook  temperature  humidity  wind    play_tennis);               
my @cases      = qw(
		    sunny    hot          high      weak    no
		    sunny    hot          high      strong  no
		    overcast hot          high      weak    yes
		    rain     mild         high      weak    yes
		    rain     cool         normal    weak    yes
		    rain     cool         normal    strong  no
		    overcast cool         normal    strong  yes
		    sunny    mild         high      weak    no
		    sunny    cool         normal    weak    yes
		    rain     mild         normal    weak    yes
		    sunny    mild         normal    strong  yes
		    overcast mild         high      strong  yes
		    overcast hot          normal    weak    yes
		    rain     mild         high      strong  no
		   );
my $outcome = pop @attributes;


my $dtree = new AI::DecisionTree;
while (@cases) {
  my @values = splice @cases, 0, 1 + scalar(@attributes);
  my $result = pop @values;
  my %pairs;
  @pairs{@attributes} = @values;

  $dtree->add_instance(attributes => \%pairs,
		       result => $result,
		      );
}
$dtree->train;


# Make sure a training example is correctly categorized
my $result = $dtree->get_result(
				attributes => {
					       outlook => 'rain',
					       temperature => 'mild',
					       humidity => 'high',
					       wind => 'strong',
					      }
			       );
ok($result, 'no');

# Try a new unseen example
$result = $dtree->get_result(
				attributes => {
					       outlook => 'sunny',
					       temperature => 'hot',
					       humidity => 'normal',
					       wind => 'strong',
					      }
			       );
ok($result, 'yes');

# Make sure rule_statements() works
ok !!grep {$_ eq "if outlook='overcast' -> 'yes'"} $dtree->rule_statements;

# Make sure rule_tree() works
ok $dtree->rule_tree->[0], 'outlook';
ok $dtree->rule_tree->[1]{overcast}, 'yes';

($result, my $confidence) = $dtree->get_result(
				attributes => {
					       outlook => 'rain',
					       temperature => 'mild',
					       humidity => 'high',
					       wind => 'strong',
					      }
					      );
ok $result, 'no';
ok $confidence, 1;

#print map "$_\n", $dtree->rule_statements;
#use YAML; print Dump $dtree;

if (eval "use GraphViz; 1") {
  my $graphviz = $dtree->as_graphviz;
  ok $graphviz;

  if (0) {
    # Only works on Mac OS X
    my $file = '/tmp/tree.png';
    open my($fh), "> $file" or die "$file: $!";
    print $fh $graphviz->as_png;
    close $fh;
    system('open', $file);
  }
} else {
  skip("Skipping: GraphViz is not installed", 0);
}

# Make sure there are 8 nodes
ok $dtree->nodes, 8;

{
  # Should barf on inconsistent data
  my $t2 = new AI::DecisionTree;
  $t2->add_instance( attributes => { foo => 'bar' },
		     result => 1 );
  $t2->add_instance( attributes => { foo => 'bar' },
		     result => 0 );
  eval {$t2->train};
  ok( "$@", '/Inconsistent data/' );
}

{
  # Make sure two trees can be trained concurrently
  my $t1 = new AI::DecisionTree;
  my $t2 = new AI::DecisionTree;
  
  my @train = (
	       [farming => 'sheep very valuable farming'],
	       [farming => 'farming requires many kinds animals'],
	       [vampire => 'vampires drink blood vampires may staked'],
	       [vampire => 'vampires cannot see their images mirrors'],
	      );
  foreach my $doc (@train) {
    $t1->add_instance( attributes => {map {$_,1} split ' ', $doc->[1]},
		       result => 0+($doc->[0] eq 'farming'));
  }
  foreach my $doc (@train) {
    $t2->add_instance( attributes => {map {$_,1} split ' ', $doc->[1]},
		       result => 0+($doc->[0] eq 'vampire'));
  }
  
  $t1->train;
  $t2->train;
  ok(1);

  my @test = (
	      [farming => 'I would like to begin farming sheep'],
	      [vampire => "I see that many vampires may have eaten my beautiful daughter's blood"],
	     );

  foreach my $doc (@test) {
    my $result = $t1->get_result( attributes => {map {$_,1} split ' ', $doc->[1]} );
    ok $result, 0+($doc->[0] eq 'farming');

    $result = $t2->get_result( attributes => {map {$_,1} split ' ', $doc->[1]} );
    ok $result, 0+($doc->[0] eq 'vampire');
  }

}

package App::LedgerSMB::Gateway::Internal;
use App::LedgerSMB::Auth qw(authenticate);
use lib "/opt/ledgersmb/";
use LedgerSMB::Sysconfig;
use Log::Log4perl;
use Dancer ':syntax';
use Dancer::Serializer;
use Dancer::Response;
use Dancer::Plugin::Ajax;
use LedgerSMB::App_State;
use LedgerSMB::GL;
use LedgerSMB::AA;
use LedgerSMB::IS;
use LedgerSMB::IR;
use LedgerSMB::DBObject::Account;
use LedgerSMB::Locale;
use LedgerSMB::Form;
Log::Log4perl::init(\$LedgerSMB::Sysconfig::log4perl_config);
my $locale = bless {}, 'LedgerSMB::Locale';

use Dancer ':syntax';
prefix '/lsmbgw/0.1/:company/internal';
our $VERSION = '0.1';

get '/gl/:id' => sub { return to_json(get_gl(param('id'))) };

=head2 get_gl(int id)

Takes in an int, returns a hashref in the following structure, or
nothing if gl not found.

=over

=item reference

The reference document number, unique per general journal entry.

=item description

A description of the transaction (free-form)

=item postdate

The date (yyyy-mm-dd format) when the transacction was posted.

=item lineitems

List of line items in the following format:

=over

=item account_number

=item account_description

=item amount

=back

=back

=cut

sub get_gl {
    my ($id) = @_;
    my $db = authenticate(
            host   => $LedgerSMB::Sysconfig::db_host,
            port   => $LedgerSMB::Sysconfig::db_port,
            dbname => param('company'),
    );
    my $form = new_form($db);
    $form->{id} = $id;
    GL->transaction({}, $form);
    $form->{dbh}->rollback;
    return {
		reference => $form->{reference},
		postdate  => $form->{transdate},
		description => $form->{description},
		lineitems => [_convert_lines_from_gl($form->{GL})],
    };
}

sub _convert_lines_from_gl {
    my ($lines) = (@_);
    return unless ref $lines;
    return 
    map { {
         account_number => $_->{accno},
	 account_description => $_->{description},
	 amount => $_->{amount},
    } } @$lines;
}

post '/gl/new' => sub { redirect(save_gl(from_json(request->body))) };

=head2 save_gl

Takes in a gl in format above and saves it, returning the new id.

=cut

sub save_gl {
    my ($struct) = @_;
    my $db = authenticate(
            host   => $LedgerSMB::Sysconfig::db_host,
            port   => $LedgerSMB::Sysconfig::db_port,
            dbname => param('company'),
    );
    my $form = new_form($db, $struct);
    local $LedgerSMB::App_State::DBH = $form->{dbh};;
    local $LedgerSMB::App_State::User = {numberformat => '1000.00'};
    _unfold_gl_lines($form);
    GL->post_transaction({}, $form, $locale);
    $form->{dbh}->commit;
    return $form->{id};
}

sub _unfold_gl_lines{
    my ($struct) = @_;
    my $i = 0;
    my $acinterface = LedgerSMB::DBObject::Account->new(base => $struct);
    my %account = map {$_->{accno} => $_ } $acinterface->list();
    $struct->{transdate} = $struct->{postdate};
    for my $l (@{$struct->{lineitems}}){
        $struct->{"credit_$i"} = $l->{amount};
	$struct->{"accno_id_$i"} = $account{$l->{account_number}}->{id};
	$struct->{"accno_$i"} = $l->{account_number};
	++$i;
    }
    $struct->{rowcount} = $i;
}

get '/salesinvoice/:id' => sub { return to_json(get_invoice(param('id'))) };
sub get_invoice {
	my ($id) = @_;
	my $db = authenticate(
            host   => $LedgerSMB::Sysconfig::db_host,
            port   => $LedgerSMB::Sysconfig::db_port,
            dbname => param('company'),
	);
	my $form = new_form($db);
	$form->{id} = $id;
	IS->retrieve_invoice({}, $form);
	$form->{dbh}->commit;
        return {
		reference => $form->{invnumber},
		postdate  => $form->{transdate},
		description => $form->{description},
		lineitems => _convert_invoice_lines($form->{invoice_details}),
		counterparty => $form->{customernumber},
	};	
}

sub _convert_invoice_lines {
    my ($ref) = @_;
    return [] unless ref $ref;
    return [
    map { {
        product_number => $_->{partnumber},
        quantity => $_->{qty}->bstr,
        sellprice => $_->{sellprice}->bstr,
        discount => $_->{discount}->bstr,	
	description => $_->{description},
    } } @$ref
    ];
}

post '/salesinvoice/new' => sub { redirect(save_gl(from_json(request->body))) };
sub save_invoice {

	my $db = authenticate(
            host   => $LedgerSMB::Sysconfig::db_host,
            port   => $LedgerSMB::Sysconfig::db_port,
            dbname => param('company'),
	);
	my $body = request->body;
	my $struct = from_json($body);
	my $form = new_form($db, $struct);
	local $LedgerSMB::App_State::DBH = $form->{dbh};;
	local $LedgerSMB::App_State::User = {numberformat => '1000.00'};
	IS->post({}, $form, $locale);
	$form->{dbh}->commit;
	return $form->{id};
}

sub get_payment {
}

sub save_payment {
}

sub get_counterparty {
}

sub save_counterparty {
}

sub new_form {
   my ($db, $struct) = @_;
   $struct ||= {};
   my $form = bless {}, 'Form';
   $form->{dbh} = $db->connect({ AutoCommit => 0 });
   $form->{$_} = $struct->{$_} for keys %$struct; 
   return $form;
}


1;



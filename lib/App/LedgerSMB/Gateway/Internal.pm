package App::LedgerSMB::Gateway::Internal;
use App::LedgerSMB::Auth qw(authenticate);
use lib "/home/chris/ledgersmb";
use Try::Tiny;
use App::LedgerSMB::Gateway::Internal::Locale;
use LedgerSMB::Sysconfig;
use Log::Log4perl;
use Dancer ':syntax';
use Dancer::HTTP;
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

# next are for counterparty
use LedgerSMB::Entity::Company;
use LedgerSMB::Entity::Person;
use LedgerSMB::Entity::Credit_Account;
use LedgerSMB::Entity::Person::Employee;
use LedgerSMB::Entity::Payroll::Wage;
use LedgerSMB::Entity::Payroll::Deduction;
use LedgerSMB::Entity::Location;
use LedgerSMB::Entity::Contact;
use LedgerSMB::Entity::Bank;
use LedgerSMB::Entity::Note;
use LedgerSMB::Entity::User;

Log::Log4perl::init(\$LedgerSMB::Sysconfig::log4perl_config);
my $locale = App::LedgerSMB::Gateway::Internal::Locale->new();

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
    status 'not_found' unless $form->{reference};
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
         reference => $_->{source},
         description => $_->{memo},
         
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
    try {
        GL->post_transaction({}, $form, $locale);
    } catch {
        Dancer::HTTP->status(400);
    }
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

get 'ar/:id' => sub { to_json(get_aa(param('id'), 'AR'))};
get 'ap/:id' => sub { to_json(get_aa(param('id'), 'AP'))};

my %vcmap = (
    'AR' => 'customer',
    'AP' => 'vendor',
);

sub get_aa {
	my ($id, $arap) = @_;
	my $db = authenticate(
            host   => $LedgerSMB::Sysconfig::db_host,
            port   => $LedgerSMB::Sysconfig::db_port,
            dbname => param('company'),
	);
	my $form = new_form($db);
	$form->{id} = $id;
	$form->{arap} = lc($arap);
	$form->{ARAP} = uc($arap);
	$form->{vc} = $vcmap{$arap};
	AA->transaction({}, $form);
	$form->{dbh}->commit;
        return {
		reference => $form->{invnumber},
		postdate  => $form->{transdate},
		description => $form->{description},
		lineitems => $form->{$form->{ARAP}},
		counterparty => $form->{"$form->{vc}number"},
	};	
}
post 'ar/new' => sub { redirect(save_aa(from_json(request->body)))};
post 'ap/new' => sub { redirect(save_aa(from_json(request->body)))};

sub save_aa {
    die 'Not implemented';
}

sub get_payment {
}

sub save_payment {
}

get 'account/:id' => sub { to_json(get_account(param('id'))) };
post 'account/new' => sub { redirect(save_account(from_json(request->body))) };

sub get_account {
    my ($id) = @_;
    my $db = authenticate(
            host   => $LedgerSMB::Sysconfig::db_host,
            port   => $LedgerSMB::Sysconfig::db_port,
            dbname => param('company'),
    );
    local $LedgerSMB::App_State::DBH = $db->connect({AutoCommit => 0 });
    local $LedgerSMB::App_State::User = {numberformat => '1000.00'};
    my ($account) = LedgerSMB::DBObject::Account->get($id);
    return _from_account($account);
}

my $category = {
   A => 'Asset',
   L => 'Liability',
   Q => 'Equity',
   E => 'Expense',
   I => 'Income',
};

my $rcategory = { map { $category->{$_} => $_ } keys %$category };

sub _from_account {
    my ($lsmb_act) = @_;
    return {
        id => $lsmb_act->{id},
	account_number => $lsmb_act->{accno},
        description => $lsmb_act->{description},
        account_type => $category->{$lsmb_act->{category}},
        
    };
}

sub _to_account {
    my ($neutral) = $_;
    return {
        id => $neutral->{id},
        accno => $neutral->{accno},
        description => $neutral->{description},
        category => $rcategory->{$neutral->{account_type}},
        
    };
}

sub save_account {
    my ($in_account) = ($_);
    my $db = authenticate(
            host   => $LedgerSMB::Sysconfig::db_host,
            port   => $LedgerSMB::Sysconfig::db_port,
            dbname => param('company'),
    );
    local $LedgerSMB::App_State::DBH = $db->connect({AutoCommit => 0 });
    local $LedgerSMB::App_State::User = {numberformat => '1000.00'};
    my $account = LedgerSMB::DBObject::Account->new(base => _to_account($in_account));
    $account->save;
    return $account->{id};
}

get 'counterparty/:id' => sub { to_json(get_counterparty(param('id'))) };
sub get_counterparty {
    my ($control_code) = @_;
    my $db = authenticate(
            host   => $LedgerSMB::Sysconfig::db_host,
            port   => $LedgerSMB::Sysconfig::db_port,
            dbname => param('company'),
    );
    local $LedgerSMB::App_State::DBH = $db->connect({AutoCommit => 0 });
    local $LedgerSMB::App_State::User = {numberformat => '1000.00'};
    my $entity =
         LedgerSMB::Entity::Company->get_by_cc($control_code);
    $entity ||=  LedgerSMB::Entity::Person->get_by_cc($control_code);
    $entity->{credit_accounts} = [ LedgerSMB::Entity::Credit_Account->list_for_entity(
                     $entity->{id},
                     $entity->{entity_class}
    ) ];
    $entity->{addresses} = [ LedgerSMB::Entity::Location->get_active(
                   {entity_id => $entity->{id},
                    credit_id => undef }
    ) ];

    $entity->{contact_info} = [ LedgerSMB::Entity::Contact->list(
              {entity_id => $entity->{id},
               credit_id => undef, }
    ) ];
    $entity->{bank_accounts} = [ LedgerSMB::Entity::Bank->list($entity->{id}) ];
    $entity->{comments} = [ LedgerSMB::Entity::Note->list($entity->{id},
			            undef) ];
    $LedgerSMB::App_State::DBH->commit;    
    return($entity);

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



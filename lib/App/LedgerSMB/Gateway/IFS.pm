package App::LedgerSMB::Gateway::IFS;

use Dancer ':syntax';

use App::LedgerSMB::Auth qw(authenticate);
use LedgerSMB::App_State;
use LedgerSMB::Sysconfig;
use LedgerSMB::Entity;
use LedgerSMB::Entity::Company;
use LedgerSMB::Entity::Credit_Account;
use LedgerSMB::IC;
use LedgerSMB::IS;
use LedgerSMB::IR;
use LedgerSMB::Form;
use Try::Tiny;

prefix '/lsmbgw/0.1/:company/quickbooks';
our $VERSION = '0.1';

sub eca_save {
    my ($entity_class, $cust) = @_;
    my $config = get_accounts_config();
    my $company = LedgerSMB::Entity::Company->get_by_cc($cust->{ListID});
    if ($company){
        my ($eca) = LedgerSMB::Entity::Credit_Account->list_for_entity($company->entity_id);
        return $eca->{id} if $eca;
    } else {
        $company = LedgerSMB::Entity::Company->new(
	    control_code => $cust->{ListID},
	    legal_name => $cust->{FullName},
	    entity_class => $entity_class,
            country_id => 232
        );
        $company->save;
        $company = $company->get_by_cc($company->control_code);
    }
    my $eca = LedgerSMB::Entity::Credit_Account->new(
	    entity_id => $company->entity_id,
	    entity_class => $entity_class,
            ar_ap_account_id => $config->{ar},
    );
    $eca->save;
    return $eca->{id};
}

sub get_part{
    my ($line) = @_;
    my $sql = "SELECT * FROM part WHERE partnumber = ?";
    my $sth = LedgerSMB::App_State::DBH->prepare($sql);
    $sth->execute($line->{ListID});
    return $sth->fetchrow_hashref('NAME_lc');
}

sub get_accounts_config{
    my $setname = 'GW-qbaccounts';
    my $config_json = LedgerSMB::Setting->get($setname);
    return from_json($config_json) if $config_json;
    # create accounts
    # 1000-lsmbpay, our internal payment
    my $acc1100 = LedgerSMB::DBObject::Account->new(base => {
        accno => '1100-lsmbar',
        category => 'A',
	description => 'internal lsmb gateway ar acct',
	link => ['AR']
    });
    my $acc2100 = LedgerSMB::DBObject::Account->new(base => {
        accno => '2100-lsmbap',
        category => 'L',
        description => 'internal lsmb gateway ar acct',
        link => ['AP']
    });
    $acc2100->save;

    $acc1100->save;
    my $acc1000 = LedgerSMB::DBObject::Account->new(base => {
        accno => '1000-lsmbpay',
        category => 'A',
	description => 'internal lsmb gateway payment acct',
	link => ['AR_paid', 'AP_paid']
    });
    $acc1000->save;
    # 1500-lsmbinv, our internal inventory assets
    my $acc1500 = LedgerSMB::DBObject::Account->new(base => {
        accno => '1500-lsmbpay',
        category => 'A',
	description => 'internal lsmb gateway inventory acct',
	link => ['IC']
        
    });
    $acc1500->save;
    # 4500-lsmbinv, our internal sales revenue
    my $acc4500 = LedgerSMB::DBObject::Account->new(base => {
        accno => '4500-lsmbinv',
        category => 'I',
	description => 'internal lsmb revenue acct',
	link => ['AR_amount', 'IC_sale']
    });
    $acc4500->save;
    # 5500-lsmbinv, our internal cogs
    my $acc5500 = LedgerSMB::DBObject::Account->new(base => {
        accno => '5500-lsmbinv',
        category => 'E',
	description => 'internal lsmb gateway cogs acct',
	link => ['AP_amount', 'IC_cogs']
    });
    $acc5500->save;
    # save map
    my $map = {
        ar => $acc1100->{id},
       pay => $acc1000->{id}, 
       inventory => $acc1500->{id},
       sales => $acc4500->{id},
       cogs => $acc5500->{id},
    };
    my $setting = LedgerSMB::Setting->set($setname, to_json($map));
    return $map;
}

sub parts_save {
    my ($line) = @_;
    my $part = get_part($line);
    if ($part){
        return {
           id => $part->{id},
           description => $line->{Desc},
           sellprice => $line->{Rate},
	   qty => $line->{Quantity},
	};
    } else {
        my $config = get_accounts_config();
        my $part = {
           partnumber => $line->{ListID},
           description => $line->{Desc}, 
           IC_income => '4500-lsmbinv',
           IC_expense => '5500-lsmbinv',
	   IC_inventory => '1500-lsmbinv',
           sellprice => $line->{Rate},
           dbh => $LedgerSMB::App_State::DBH,
        };
        bless $part, 'Form';
        IC->save({}, $part);
        return {
           id => $part->{id},
           description => $line->{Desc},
           sellprice => $line->{Rate},
	   qty => $line->{Quantity},
	};
    }
}

sub bill_save {
    my ($struct) = @_;
    my $db = authenticate(
            host   => $LedgerSMB::Sysconfig::db_host,
            port   => $LedgerSMB::Sysconfig::db_port,
            dbname => param('company'),
    );
    local $LedgerSMB::App_State::DBH = $db->connect({ AutoCommit => 1 });
    local $LedgerSMB::App_State::User = {numberformat => '1000.00'};
    $struct = App::LedgerSMB::Gateway::Quickbooks::unwrap_qbxml($struct, ['BillQueryRs', 'BillQueryRet']);
    if (ref $struct eq 'ARRAY') {
        bill_save($_) for @$struct;
        return 'success';
    }
    $struct->{vendor_id} = eca_save(1, $struct->{VendorRef});
    $_->{part_id} = parts_save($_) for @{$struct->{ItemLineRet}};
    return save_vendorinvoice(bill_to_vi($struct));
}

sub bill_to_vi {
    my ($struct) = @_;
    my $initial = {
        vc => 'vendor',
        transdate => $struct->{TxnDate},
        currency => 'USD',
        exchangerate => 1,
	arap => 'ap',
	ARAP => 'AP',
        vendor_id => $struct->{vendor_id},
        AP => '1100-lsmbar'
    };
    my $rowcount = 0;
    $struct->{InvoiceLineRet} = [$struct->{InvoiceLineRet}] if ref $struct->{InvoiceLineRet} eq 'HASH';
    for (@{$struct->{InvoiceLineRet}}){
        my $linestruct = parts_save($_);
        $initial->{"${_}_$rowcount"} = $linestruct->{$_} for keys %$linestruct;
	++$rowcount;
    }
    $initial->{rowcount} = $rowcount;
    return $initial;
}

sub invoice_save {
    my ($struct) = @_;
    my $db = authenticate(
            host   => $LedgerSMB::Sysconfig::db_host,
            port   => $LedgerSMB::Sysconfig::db_port,
            dbname => param('company'),
    );
    local $LedgerSMB::App_State::DBH = $db->connect({ AutoCommit => 1 });
    local $LedgerSMB::App_State::User = {numberformat => '1000.00'};
    $struct = App::LedgerSMB::Gateway::Quickbooks::unwrap_qbxml($struct, ['InvoiceQueryRs', 'InvoiceRet']);
    if (ref $struct eq 'ARRAY') {
        invoice_save($_) for @$struct;
        return 'success';
    }
    $struct->{customer_id} = eca_save(2, $struct->{CustomerRef});
    return save_salesinvoice(invoice_to_si($struct));
}

sub save_vendorinvoice {
    my ($struct) = @_;
    my $form = App::LedgerSMB::Gateway::Internal::new_form(undef, $struct);
    try {
        IR->post_invoice({}, $form);
    } catch {
        warning($_);
    };
    return 'success';
}

sub save_salesinvoice {
    my ($struct) = @_;
    my $form = App::LedgerSMB::Gateway::Internal::new_form(undef, $struct);
    try {
        IS->post_invoice({}, $form);
    } catch {
        warning($_);
    };
    return 'success';
}

sub invoice_to_si {
    my ($struct) = @_;
    my $initial = {
        vc => 'customer',
        transdate => $struct->{TxnDate},
        currency => 'USD',
        exchangerate => 1,
	arap => 'ar',
	ARAP => 'AR',
	customer_id => $struct->{customer_id},
        AR => '1100-lsmbar'
    };
    my $rowcount = 0;
    $struct->{InvoiceLineRet} = [$struct->{InvoiceLineRet}] if ref $struct->{InvoiceLineRet} eq 'HASH';
    for (@{$struct->{InvoiceLineRet}}){
        my $linestruct = parts_save($_);
        $initial->{"${_}_$rowcount"} = $linestruct->{$_} for keys %$linestruct;
	++$rowcount;
    }
    $initial->{rowcount} = $rowcount;
    return $initial;
}

post '/purchase/new' => sub {warning(request->body); bill_save(from_json(request->body)); to_json({success => 1})};

post '/sales/new' => sub {warning(request->body); invoice_save(from_json(request->body)); to_json({success => 1})};

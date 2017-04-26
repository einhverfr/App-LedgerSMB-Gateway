package App::LedgerSMB::Gateway::IFS;

use Dancer ':syntax';

use App::LedgerSMB::Auth qw(authenticate);
use LedgerSMB::Entity;
use LedgerSMB::Entity::Company;
use LedgerSMB::Entity::Credit_Account;
use LedgerSMB::IC;
use LedgerSMB::IS;
use LedgerSMB::IR;

prefix '/lsmbgw/0.1/:company/quickbooks';
our $VERSION = '0.1';

sub eca_save {
    my ($entity_class, $cust) = @_;
    my $company = LedgerSMB::Entity::Company->new(
	    control_code => $cust->{ListID},
	    legal_name => $cust->{FullName},
	    entity_class => $entity_class,
    );
    $company->save;
    my $eca = LedgerSMB::Entity::Credit_Account->new(
	    entity_id => $company->{entity_id},
	    entity_class => $entity_class,
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
    my $acc1000 = LedgerSMB::DBObject::Account->new(base => {
        accno => '1000-lsmbpay',
	description => 'internal lsmb gateway payment acct',
	link => ['AR_paid', 'AP_paid']
    });
    $acc1000->save;
    # 1500-lsmbinv, our internal inventory assets
    my $acc1500 = LedgerSMB::DBObject::Account->new(base => {
        accno => '1500-lsmbpay',
	description => 'internal lsmb gateway inventory acct',
	link => ['IC']
        
    });
    $acc1500->save;
    # 4500-lsmbinv, our internal sales revenue
    my $acc4500 = LedgerSMB::DBObject::Account->new(base => {
        accno => '4500-lsmbinv',
	description => 'internal lsmb revenue acct',
	link => ['AR_amount', 'IC_sale']
    });
    $acc4500->save;
    # 5500-lsmbinv, our internal cogs
    my $acc5500 = LedgerSMB::DBObject::Account->new(base => {
        accno => '5500-lsmbinv',
	description => 'internal lsmb gateway cogs acct',
	link => ['AP_amount', 'IC_cogs']
    });
    $acc5500->{save};
    # save map
    my $map = {
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
    if (get_part($line)){
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
           income_accno_id => $config->{sales},
           expense_accno_id => $config->{cogs},
	   inventory_accno_id => $config->{inventory},
           sellprice => $line->{Rate},
        };
        IC->save({}, $part);
        return {
           id => $part->{id},
           description => $line->{Desc},
           sellprice => $line->{Rate},
	   qty => $line->{Quantity},
	};
        }
    }
}

sub bill_save {
    my $db = authenticate(
            host   => $LedgerSMB::Sysconfig::db_host,
            port   => $LedgerSMB::Sysconfig::db_port,
            dbname => param('company'),
    );
    local $LedgerSMB::App_State::DBH = $db->connect({ AutoCommit => 1 });
    local $LedgerSMB::App_State::User = {numberformat => '1000.00'};
    my ($struct) = @_;
    $struct = App::LedgerSMB::Gateway::Quickbooks::unwrap_qbxml(['BillQueryRs', 'BillQueryRet']);
    if (ref $struct eq 'ARRAY') {
        bill_save($_) for @$struct;
    }
    $struct->{vendor_id} = eca_save(1, $struct->{VendorRef});
    $_->{part_id} = parts_save($_) for @{$struct->{ItemLineRet}};
    return save_vendorinvoice(bill_to_vi($struct));
}

sub bill_to_vi {
    my ($struct) = @_;
    my $initial = {
        vc => 'vendor',
	arap => 'ap',
	ARAP => 'AP',
        vendor_id => $struct->{vendor_id},
    };
    $rowcount = 0;
    for (@{$struct->{InvoiceLineRet}){
        $linestruct = parts_save($_);
        $initial->{"${_}_$rowcount"} = $linestruct->{$_} for keys %$linestruct;
	++$rowcount;
    }
    $initial->{rowcount} = $rowcount};
}

sub invoice_save {
    my $db = authenticate(
            host   => $LedgerSMB::Sysconfig::db_host,
            port   => $LedgerSMB::Sysconfig::db_port,
            dbname => param('company'),
    );
    local $LedgerSMB::App_State::DBH = $db->connect({ AutoCommit => 1 });
    local $LedgerSMB::App_State::User = {numberformat => '1000.00'};
    my ($struct) = @_;
    $struct = App::LedgerSMB::Gateway::Quickbooks::unwrap_qbxml(['InvoiceQueryRs', 'InvoiceRet']);
    if (ref $struct eq 'ARRAY') {
        invoice_save($_) for @$struct;
    }
    $struct->{customer_id} = eca_save(2, $struct->{CustomerRef});
    return save_salesinvoice(invoice_to_si($struct));
}

sub save_vendorinvoice {
    my ($struct) = @_;
    my $form = App::LedgerSMB::Gateway::Internal::new_form($struct);
    try {
        IR->save({}, $form);
    } catch {
        warning($_);
    };
    return 'success';
}

sub save_salesinvoice {
    my ($struct) = @_;
    my $form = App::LedgerSMB::Gateway::Internal::new_form($struct);
    try {
        IS->save({}, $form);
    } catch {
        warning($_);
    };
    return 'success';
}

sub invoice_to_si {
    my ($struct) = @_;
    my $initial = {
        vc => 'customer',
	arap => 'ar',
	ARAP => 'AR',
	customer_id => $struct->{customer_id},
    };
    $rowcount = 0;
    for (@{$struct->{InvoiceLineRet}){
        $linestruct = parts_save($_);
        $initial->{"${_}_$rowcount"} = $linestruct->{$_} for keys %$linestruct;
	++$rowcount;
    }
    $initial->{rowcount} = $rowcount};
}

post '/purchase/new' => sub {warning(request->body); bill_save(from_json(request->body)); to_json({success => 1})};

post '/sales/new' => sub {warning(request->body); invoice_save(from_json(request->body)); to_json({success => 1})};

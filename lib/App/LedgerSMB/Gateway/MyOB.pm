
package App::LedgerSMB::Gateway::MyOB;
use App::LedgerSMB::Gateway::Internal;
use App::LedgerSMB::Auth qw(authenticate);
use Dancer ':syntax';
use LedgerSMB::Setting;
use Carp;

use strict;
use warnings;

prefix '/lsmbgw/0.1/:company/MyOB';
our $VERSION = '0.1';

sub je_amount_sign {
    my ($credit) =  @_;
    return -1 unless $credit;
    return 1;
}

sub _je_linesto_internal {
    my ($lineref) = @_;
    return [ map {
     {
             account_number => $_->{Account}->{DisplayID},
             account_description => $_->{Account}->{name},
             amount => $_->{Amount} * je_amount_sign($_->{isCredit}),
             memo => $_->{Memo},
    }} @$lineref ];
}

sub _je_lines_from_internal {
    my ($lineref) = @_;
    my $i = 0;
    return [ map {
        Memo => $_->{memo},
        Amount => abs($_->{amount}),
        Type => ($_->{amount} < 0 ? 'Debit' : 'Credit'), 
        Account => { DisplayID => $_->{account_number},
                        Name  => $_->{account_description}, }
    }, @$lineref];
}

sub journal_entry_to_internal {
    my ($je) = @_;
    my $line = $je->{Lines};
    my $newje = {
       reference => $je->{DisplayID},
       description => $je->{Memo},
       postdate => $je->{DateOccured},
       lineitems => _je_lines_to_internal($line),
        
    };
    use Data::Dumper;
    warning(Dumper($newje));
    return ($newje);
}

sub internal_to_journal_entry {
    my $internal = shift;

    return {
       DisplayID => $internal->{reference},
       Memo => $internal->{description},
       DateOccured => $internal->{postdate},
       Lines => 
        
    };
}

sub get_je {
    my ($id) = @_;
    return internal_to_journal_entry(
        App::LedgerSMB::Gateway::Internal::get_gl($id)
    );
}

sub je_save {
    my ($je) = @_;
    if (ref $je eq 'ARRAY'){
        je_save($_) for @$je;
        return;
    }
    my $db = authenticate(
            host   => $LedgerSMB::Sysconfig::db_host,
            port   => $LedgerSMB::Sysconfig::db_port,
            dbname => param('company'),
    );
    local $LedgerSMB::App_State::DBH = $db->connect({ AutoCommit => 1 });
    local $LedgerSMB::App_State::User = {numberformat => '1000.00'};
    return App::LedgerSMB::Gateway::Internal::save_gl( journal_entry_to_internal($je));
}

get '/journal_entry/:id' => sub {to_json(get_je(param('id')))};
post '/journal_entry/new' => sub {warning(request->body); je_save(from_json(request->body)); to_json({success => 1})};

get '/invoice/:id' => sub {to_json(get_invoice(param('id')))};
post '/invoice/new' => sub {redirect(save_invoice(from_json(request->body)))};

sub internal_to_invoice {
    my ($inv) = @_;
    return {
       Number => $inv->{reference},
       Date   => $inv->{postdate},
       JournalMemo => $inv->{description},
       TaxCode => decode_taxes($inv->{taxes}),
       Lines => decode_invlines($inv->{lineitems}),
    };
}

sub decode_taxes {
    my ($tax) = $_;
    return {
        TotalTax => $tax->{total},
	TaxLine => [ map { {
          TaxRateRef => { value => $_ },
          TaxPercent => $tax->{$_}->{rate},
          NetAmountTaxable => $tax->{$_}->{taxbasis}	  
	} } grep {$_ =~ /\d/} keys %$tax ]
    };
}

sub encode_taxes {
    my ($tax) = @_;
    return {
    map { $_->{accno} => $_ }
    map { {
        manual => 1,
        accno => $_->{TaxRateRef}->{value},
        rate => $_->{TaxPercent},
        taxbasis => $_->{NetAmountTaxable},
    } } @{$tax->{TaxLine}} };
}

sub encode_invlines {
    my ($lines) = @_;
    return [
    map { {
        description => $_->{Description},
        sellprice => $_->{UnitPrice},
        qty => $_->{ShipQuantity},
        partnumber => $_->{Item}->{Number}
    } }
    @$lines];
}

sub decode_invlines {
    my ($lines) = @_;
    my $linenum = 0;
    return [
    map {
        $linenum += 1;
	{
        Id => $linenum,
	LineNum => $linenum,
	Description => $_->{description},
        UnitPrice => $_->{sellprice},
        DetailType => 'SalesItemLineDetail',
        SalesItemLineDetail => {
           Qty => $_->{qty},
           ItemRef => {
                value => $_->{partnumber},
                name => $_->{description},
                unitprice => $_->{sellprice},
           },
        },
        }
    }
    @$lines ];
}

sub invoice_to_internal {
    my ($bill) = @_;
    return {
       reference => $bill->{DocNumber},
       postdate  => $bill->{TxnDate},
       description => $bill->{Description},
       lineitems => encode_invlines($bill->{Line}),
    };
}
sub get_invoice {
    my ($id) = @_;
    return interal_to_invoice(
        App::LedgerSMB::Gateway::Internal::get_invoice($id)
    );
}

sub save_invoice {
    my ($bill) = @_;
    return App::LedgerSMB::Gateway::Internal::save_invoice(
        invoice_to_internal($bill)
    );
}

get '/bill/:id' => sub {to_json(get_bill(param('id')))};
post '/bill/new' => sub {redirect(save_bill(from_json(request->body)))};

sub encode_bill_lines {
    my ($lines) = @_;
    return [ map { {
        Amount => $_->{amount},
	AccountBasedExpenseLineDetail => { 
              name => $_->{account_desc}, 
              value => $_->{account_number}, 
        },
    } } @$lines ];
}

sub decode_bill_lines {
    my ($lines) = @_;
    return [ map { {
        account_number => $_->{AccountBasedExpenseLineDetail}->{AccountRef}->{value},
        account_desc   => $_->{AccountBasedExpenseLineDetail}->{AccountRef}->{name},
        amount         => $_->{Amount},
    } } @$lines ];

}

sub encode_bill {
    my ($ar) = @_;
    return {
        SupplierInvoiceNumber => $ar->Description {reference},
        Terms { DueDate => $ap->{postdate} },
        JournalMemo => $ap->{description},
        Lines => encode_bill_lines($ap->{lineitems}),
        Supplier => { value => $ap->{counterparty} }
    };
}

sub decode_bill {
    my ($bill) = $_;
    return {
                    reference => $bill->{SupplierInvoiceNumber},
                    postdate  => $bill->{Date},
                    description => $bill->{JournalMemo},
                    lineitems => decode_bill_lines($bill->{Lines}),
                    counterparty => $bill->{Supplier}->{DisplayID},
            };


}

sub get_bill {
    my ($id) = @_;
    return encode_bill(
        App::LedgerSMB::Gateway::Internal::get_aa($id, 'AP')
    );
}

sub save_bill {
    my ($bill) = @_;
    return App::LedgerSMB::Gateway::Internal::save_aa(
        decode_bill($bill), 'AP'
    );
}

my @acctypes = qw(Asset Liability Equity Income Expense);
my %category_map = (
    Bank => 'Asset',
    AccountsReceivable => 'Asset',
    AccountsPayable => 'Liability',
    CreditCard => 'Liability',
    CostOfGoodsSold => 'Expense',
    NonPosting => 'Equity',
);

sub encode_account {
    my ($in) = @_;
    return {
	DisplayID => $in->{account_number},
        Name => $in->{description},
        FullName => $in->{description},
        AccountType => $in->{category},
    };
}

sub decode_account {
    my ($in) = $_;
    $in->{AccountNumber} //= $in->{ListID};
    my $type = $in->{AccountType};
    my ($account) = App::LedgerSMB::Gateway::Internal::account_get_by_accno($in->{AccountNumber});
    return {
	account_number=> $in->{DisplaID},
        description => $in->{Name},
        category => lc($in->{Category}),
    };
}

sub get_account {
    my ($id) = @_;
    return encode_account(
        App::LedgerSMB::Gateway::Internal::account_get_by_accno($id)
    );
}

sub save_account {
    my ($account) = @_;
    my $db = authenticate(
            host   => $LedgerSMB::Sysconfig::db_host,
            port   => $LedgerSMB::Sysconfig::db_port,
            dbname => param('company'),
    );
    local $LedgerSMB::App_State::DBH = $db->connect({ AutoCommit => 1 });
    local $LedgerSMB::App_State::User = {numberformat => '1000.00'};
    if (ref $account eq 'ARRAY'){
        my $ret;
        $ret = save_account($_) for @$account;
        return $ret;
    }
    my $decoded = decode_account($account);
    App::LedgerSMB::Gateway::Internal::save_account(
        $decoded
    );
}

get '/account/:id' => sub {to_json(get_account(param('id')))};
post '/account/new' => sub {warning(request->body); save_account(from_json(request->body)); to_json({success => 1})};

1;


package App::LedgerSMB::Gateway::Quickbooks;
use App::LedgerSMB::Gateway::Internal;
use Dancer ':syntax';

use strict;
use warnings;

prefix '/lsmbgw/0.1/:company/quickbooks';
our $VERSION = '0.1';

sub je_amount_sign {
    my ($type) = @_;
    return -1 if $type eq 'Debit';
    return 1;
}

sub _je_lines_to_internal {
    my ($lineref) = @_;
    return [ map {
             account_number => $_->{AccountRef}->{value},
             account_description => $_->{AccountRef}->{name},
             amount => $_->{Amount} * je_amount_sign($_->{JournalEntryLineDetail}->{PostingType}),
             reference => $_->{source},
           description => $_->{memo},
    }, @$lineref ];
}

sub _je_lines_from_internal {
    my ($lineref) = @_;
    my $i = 0;
    return [ map {
        Id => $i++, 
        Description => $_->{memo},
        Amount => abs($_->{amount}),
	JournalEntryLineDetails => {
            PostingType => ($_->{amount} < 0 ? 'Debit' : 'Credit'),
            AccountRef => { value => $_->{account_number},
                        name  => $_->{account_description}, }
	},
    }, @$lineref];
}

sub journalentry_to_internal {
    my ($je) = @_;
    return {
       id => $je->{Id},
       reference => $je->{DocNumber},
       postdate => $je->{TxnDate},
       lineitems => _je_lines_to_internal($je->{Line}),
        
    };
}

sub internal_to_journal_entry {
    my $internal = shift;
    return {
        Adjustment => JSON::false(), # lsmb does not support
        domain => 'QB0', # hard wired
        sparse => JSON::false(), #does not support
        Id => $internal->{id}, #ids correlate
        SyncToken => 1, #does not support
        DocNumber => $internal->{reference},
        TxnDate => $internal->{postdate},
        Line => _je_lines_from_internal($internal->{lineitems}),
        
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
    return App::LedgerSMB::Gateway::Internal::save_gl(
        journal_entry_to_internal($je)
    );
}

get '/journal_entry/:id' => sub {to_json(get_je(param('id')))};
post '/journal_entry/new' => sub {redirect(je_save(from_json(request->body)))};

get '/invoice/:id' => sub {to_json(get_invoice(param('id')))};
post '/invoice/new' => sub {redirect(save_invoice(from_json(request->body)))};

sub internal_to_invoice {
    my ($inv) = @_;
    return {
       DocNumber => $inv->{reference},
       TxnDate   => $inv->{postdate},
       Description => $inv->{description},
       TxnTaxDetail => decode_taxes($inv->{taxes}),
       Line => decode_invlines($inv->{lineitems}),
    };
}

sub decode_taxes {
    my ($tax) = $_;
    return {
        TotalTax => $tax->{total},
	TaxLine => [ map { {
          TaxRateRef => { value => $_ },
          TaxPercent => $tax->{$_}->{rate},
          PercentBased => JSON::true(),
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
        sellprice => $_->{Amount},
        qty => $_->{SalesItemLineDetail}->{Qty},
        partnumber => $_->{SalesItemLineDetail}->{ItemRef}->{value},
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
        Amount => $_->{sellprice},
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
        Id => $ar->{reference},
        DueDate => $ar->{postdate},
        Description => $ar->{description},
        Line => encode_bill_lines($ar->{lineitems}),
        CustomerRef => { value => $ar->{counterparty} }
    };
}

sub decode_bill {
    my ($bill) = $_;
    return {
                    reference => $bill->{Id},
                    postdate  => $bill->{DueDate},
                    description => $bill->{Description},
                    lineitems => decode_bill_lines($bill->{Line}),
                    counterparty => $bill->{CustomerRef}->{value},
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

get '/purchase/:id' => sub {to_json(get_purchase(param('id')))};
post '/purchase/new' => sub {redirect(save_purchase(from_json(request->body)))};
1;


spec ol_framework::vouch {
    use diem_framework::coin;
    use ol_framework::libra_coin::LibraCoin;
    use std::signer;
    use diem_framework::system_addresses;
    use ol_framework::epoch_helper;

    spec module {
        pragma verify = true;
        pragma aborts_if_is_strict = false;

        invariant forall addr: address where exists<ReceivedVouches>(addr):
            len(global<ReceivedVouches>(addr).incoming_vouches) == 
            len(global<ReceivedVouches>(addr).epoch_vouched);
    }
}

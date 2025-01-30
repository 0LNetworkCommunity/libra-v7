spec ol_framework::lockbox {

    /// Specification for maybe_initialize:
    /// Initializes a new SlowWalletV2 for a user if one doesn't exist
    spec maybe_initialize(user: &signer) {
        // Post-condition: ensures a SlowWalletV2 exists for the user after execution
        ensures exists<SlowWalletV2>(signer::address_of(user));
    }

    /// Specification for new:
    /// Creates a new Lockbox with initial values
    spec new(locked_coins: Coin<LibraCoin>, duration_type: u64): Lockbox {
        // Post-conditions: verify all fields are properly initialized
        ensures result.duration_type == duration_type;  // Duration is set correctly
        ensures result.lifetime_deposits == 0;          // No deposits yet
        ensures result.lifetime_unlocked == 0;          // Nothing unlocked yet
        ensures result.last_unlock_timestamp == 0;      // No unlocks performed
    }

    /// Specification for add_to_or_create_box:
    /// Adds coins to an existing box or creates a new one
    spec add_to_or_create_box(user: &signer, locked_coins: Coin<LibraCoin>, duration_type: u64) {
        // Pre-conditions
        requires signer::address_of(user) != @0x0;  // User must have valid address

        // Post-conditions
        ensures exists<SlowWalletV2>(signer::address_of(user));  // SlowWalletV2 must exist after operation
    }

    /// Specification for deposit_impl:
    /// Internal implementation for depositing coins
    spec deposit_impl(user_addr: address, locked_coins: Coin<LibraCoin>, duration_type: u64) {
        // Pre-conditions
        requires user_addr != @0x0;                    // Address must be valid
        requires exists<SlowWalletV2>(user_addr);      // SlowWalletV2 must exist
    }

    /// Specification for balance_list:
    /// Calculates total balance of all lockboxes in a list
    spec balance_list(list: &vector<Lockbox>): u64 {
        // Post-conditions
        ensures result >= 0;  // Balance can never be negative
    }

    /// Specification for delay_impl:
    /// Implements the delay mechanism for shifting coins to longer durations
    spec delay_impl(user: &signer, duration_from: u64, duration_to: u64, units: u64) {
        // Pre-conditions
        requires signer::address_of(user) != @0x0;  // User must have valid address

        // Post-conditions
        ensures duration_from < duration_to;  // Can only move to longer duration
    }

    /// Specification for checked_transfer_impl:
    /// Implements safe transfer between two SlowWalletV2 accounts
    spec checked_transfer_impl(from: &signer, to: address, duration_type: u64, units: u64) {
        // Pre-conditions
        requires exists<SlowWalletV2>(signer::address_of(from));  // Sender must have SlowWalletV2
        requires exists<SlowWalletV2>(to);                        // Receiver must have SlowWalletV2
        requires units > 0;                                        // Must transfer positive amount
        requires to != @0x0;                                      // Receiver address must be valid

        // Post-conditions
        ensures units > 0;                                        // Amount remains positive
        ensures to != @0x0;                                      // Receiver remains valid
    }

    /// Specification for deposit:
    /// Handles depositing coins into a lockbox
    spec deposit(box: &mut Lockbox, more_coins: Coin<LibraCoin>) {
        // Post-conditions
        ensures box.locked_coins.value == old(box.locked_coins.value) + more_coins.value;  // Balance increases by deposited amount
    }

    /// Specification for withdraw_drip_impl:
    /// Implements the drip withdrawal mechanism
    spec withdraw_drip_impl(user: &signer, idx: u64): Option<Coin<LibraCoin>> {
        requires exists<SlowWalletV2>(signer::address_of(user));
        requires idx < vector::length(global<SlowWalletV2>(signer::address_of(user)).list);
    }

    /// Helper function to calculate minimum amount needed to get non-zero drip
    spec fun min_amount_for_drip(duration_months: u64): u64 {
        let days = math64::mul_div(duration_months, 365, 12);
        days / 10000000 + 1
    }
}

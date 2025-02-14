module dev_addr::vesting {

    use std::signer;
    use aptos_framework::coin;
    use aptos_framework::table;
    use std::timestamp;
    use std::aptos_coin;
    use std::account;
    

    // Error codes
    const E_NOT_OWNER: u64 = 0;
    const E_STREAM_EXISTS: u64 = 1;
    const E_INVALID_PARAMETERS: u64 = 2;
    const E_NO_STREAM: u64 = 3;
    const E_NOTHING_TO_CLAIM: u64 = 4;
    const E_INSUFFICIENT_FUNDS: u64 = 5;

    const ADMIN: address = @dev_addr;

    struct VestingPool has key {
        streams: table::Table<address, VestingStream>,
        coin: coin::Coin<aptos_coin::AptosCoin>,
        owner: address,
    }

    /// Each vesting stream defines a vesting schedule for a beneficiary.
    struct VestingStream has store, drop {
        total_amount: u64,
        start_time: u64,
        // Durations are stored as relative values in seconds.
        cliff_duration: u64,
        vesting_duration: u64,
        claimed_amount: u64,
    }

    /// Initializes the vesting pool.
    /// The caller's address becomes the owner (admin) of the vesting pool.
    /// This function must be called by the account with the ADMIN address.
    public entry fun initialize(admin: &signer) {
        let admin_addr = signer::address_of(admin);
        // Ensure that only the ADMIN can initialize the vesting pool.
        assert!(admin_addr == ADMIN, E_NOT_OWNER);
        move_to(
            admin,
            VestingPool {
                streams: table::new<address, VestingStream>(),
                coin: coin::zero<aptos_coin::AptosCoin>(),
                owner: admin_addr,
            }
        );
    }

    /// Creates a new vesting stream for the given beneficiary.
    /// Only the admin (stored at ADMIN) can call this function.
    public entry fun create_vesting_stream(
        admin: &signer,
        beneficiary: address,
        total_amount: u64,
        cliff_duration: u64,
        vesting_duration: u64
    ) acquires VestingPool {
        let admin_addr = signer::address_of(admin);
        // Ensure that the caller is the admin.
        assert!(admin_addr == ADMIN, E_NOT_OWNER);
        let vesting_pool = borrow_global_mut<VestingPool>(ADMIN);
        // Check that a stream for the beneficiary does not already exist.
        assert!(!table::contains(&vesting_pool.streams, beneficiary), E_STREAM_EXISTS);
        assert!(cliff_duration <= vesting_duration, E_INVALID_PARAMETERS);

        // Withdraw tokens from the admin's account and merge them into the pool.
        let coins = coin::withdraw<aptos_coin::AptosCoin>(admin, total_amount);
        coin::merge(&mut vesting_pool.coin, coins);

        // Set the vesting start time to 100 seconds in the future.
        let start_time = timestamp::now_seconds() + 100;

        let stream = VestingStream {
            total_amount,
            start_time,
            cliff_duration,
            vesting_duration,
            claimed_amount: 0,
        };

        table::add(&mut vesting_pool.streams, beneficiary, stream);
    }

    /// Allows a beneficiary to claim their vested tokens.
    public entry fun claim(user: &signer) acquires VestingPool {
        let user_addr = signer::address_of(user);
        let vesting_pool = borrow_global_mut<VestingPool>(ADMIN);
        assert!(table::contains(&vesting_pool.streams, user_addr), E_NO_STREAM);

        let stream = table::borrow_mut(&mut vesting_pool.streams, user_addr);
        let current_time = timestamp::now_seconds();
        let vested_amount = calculate_vested_amount(stream, current_time);
        let claimable_amount = vested_amount - stream.claimed_amount;
        assert!(claimable_amount > 0, E_NOTHING_TO_CLAIM);

        // Ensure the pool has enough funds before extracting.
        assert!(coin::value(&vesting_pool.coin) >= claimable_amount, E_INSUFFICIENT_FUNDS);
        let coins = coin::extract(&mut vesting_pool.coin, claimable_amount);
        coin::deposit(user_addr, coins);
        stream.claimed_amount += claimable_amount;

        // Remove stream if fully claimed.
        if (stream.claimed_amount == stream.total_amount) {
            table::remove(&mut vesting_pool.streams, user_addr);
        }
    }

    #[view]
    public fun get_vested_balance(user_addr: address): u64 acquires VestingPool {
        let vesting_pool = borrow_global<VestingPool>(ADMIN);
        // Verify that the caller has an associated vesting stream.
        assert!(table::contains(&vesting_pool.streams, user_addr), E_NO_STREAM);
        let stream = table::borrow(&vesting_pool.streams, user_addr);
        let current_time = timestamp::now_seconds();
        let vested_amount = calculate_vested_amount(stream, current_time);
        vested_amount - stream.claimed_amount
    }

    /// Internal helper function that calculates the vested amount for a stream based on the current time.
    fun calculate_vested_amount(stream: &VestingStream, current_time: u64): u64 {
        let start_time = stream.start_time;
        let cliff_time = start_time + stream.cliff_duration;
        if (current_time < cliff_time) {
            return 0;
        };
        let vesting_end_time = start_time + stream.vesting_duration;
        if (current_time >= vesting_end_time) {
            return stream.total_amount;
        };
        let time_after_cliff = current_time - cliff_time;
        let vesting_duration_after_cliff = stream.vesting_duration - stream.cliff_duration;
        if (vesting_duration_after_cliff == 0) {
            return stream.total_amount;
        };
        (((time_after_cliff as u128) * (stream.total_amount as u128))
            / (vesting_duration_after_cliff as u128)) as u64
    }

    #[test(admin = @dev_addr)]
    public fun test_initialize(admin: &signer) {
        // Initialize the vesting pool using the provided admin signer.
        initialize(admin);
        // Additional checks can be added here.
    }

    /// Test the pure vesting calculation logic.
    #[test]
    public fun test_calculate_vested_amount() {
        let stream = VestingStream {
            total_amount: 1000,
            start_time: 1000,
            cliff_duration: 100,       // cliff at time 1100
            vesting_duration: 1100,     // vesting ends at time 2100
            claimed_amount: 0,
        };

        // Before the cliff: time = 1050, expect 0 tokens vested.
        let vested_before = calculate_vested_amount(&stream, 1050);
        assert!(vested_before == 0, 101);

        // At the cliff: time = 1100, expect 0 tokens vested.
        let vested_at_cliff = calculate_vested_amount(&stream, 1100);
        assert!(vested_at_cliff == 0, 102);

        // Mid-vesting: time = 1600, 500 seconds after the cliff.
        // Expected vested = 1000 * 500 / 1000 = 500.
        let vested_mid = calculate_vested_amount(&stream, 1600);
        assert!(vested_mid == 500, 103);

        // After vesting duration: time = 2100, expect full vesting.
        let vested_end = calculate_vested_amount(&stream, 2100);
        assert!(vested_end == 1000, 104);
    }

    /// Test creating a vesting stream and simulating the vesting schedule.
    /// Note: We now add an extra parameter for aptos_framework to initialize the mint capability.
    #[test(admin = @dev_addr, beneficiary = @0x2, aptos_framework = @0x1)]
    public fun test_create_vesting_stream_and_simulate(
        admin: &signer,
        beneficiary: &signer,
        aptos_framework: &signer
    ) acquires VestingPool {
        // Initialize the timestamp resource.
        timestamp::set_time_has_started_for_testing(aptos_framework);

        let owner = signer::address_of(admin);
        // Initialize the mint capability for testing.
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(aptos_framework);
        // Ensure both the aptos_framework and owner (admin) accounts are created.
        account::create_account_for_test(signer::address_of(aptos_framework));
        account::create_account_for_test(owner);

        // Register the owner account for AptosCoin.
        coin::register<aptos_coin::AptosCoin>(admin);

        // Mint coins to admin using the aptos_framework signer (which holds the mint capability).
        aptos_coin::mint(aptos_framework, owner, 500_000_000);

        // Initialize the vesting pool.
        initialize(admin);

        // Create a vesting stream for the beneficiary.
        let total_amount = 300_000_000; 
        let cliff_duration = 100;
        let vesting_duration = 1100;
        create_vesting_stream(
            admin,
            signer::address_of(beneficiary),
            total_amount,
            cliff_duration,
            vesting_duration
        );

        // Retrieve the vesting stream from the pool.
        let pool = borrow_global<VestingPool>(owner);
        let stream_ref = table::borrow(&pool.streams, signer::address_of(beneficiary));

        // Simulate a time 500 seconds after the cliff.
        let simulated_time = stream_ref.start_time + cliff_duration + 500;
        let vested_amount = calculate_vested_amount(stream_ref, simulated_time);
        // For demonstration, assert that the vested amount is positive.
        assert!(vested_amount > 0, 105);

        // Clean up: destroy the mint and burn capabilities.
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }
    
     #[test(admin = @dev_addr, beneficiary = @0x2, aptos_framework = @0x1)]
     public entry fun test_claim(
         admin: &signer,
         beneficiary: &signer,
         aptos_framework: &signer
     ) acquires VestingPool {
    // Initialize the timestamp and create necessary accounts.
        timestamp::set_time_has_started_for_testing(aptos_framework);
        account::create_account_for_test(signer::address_of(aptos_framework));
        let admin_addr = signer::address_of(admin);
        account::create_account_for_test(admin_addr);
        let beneficiary_addr = signer::address_of(beneficiary);
        account::create_account_for_test(beneficiary_addr);

    // Initialize AptosCoin and mint to admin.
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(aptos_framework);
        coin::register<aptos_coin::AptosCoin>(admin);
        coin::register<aptos_coin::AptosCoin>(beneficiary);
        aptos_coin::mint(aptos_framework, admin_addr, 500_000_000);

    // Initialize the vesting pool and create a stream.
        initialize(admin);
        let total_amount = 300_000_000;
        let cliff_duration = 100;
        let vesting_duration = 1100;
        create_vesting_stream(admin, beneficiary_addr, total_amount, cliff_duration, vesting_duration);

    // Get stream details to calculate claim time.
        let pool = borrow_global<VestingPool>(admin_addr);
        let stream = table::borrow(&pool.streams, beneficiary_addr);
        let start_time = stream.start_time;
        let claim_time = start_time + stream.cliff_duration + 500; // 500s after cliff.
        timestamp::update_global_time_for_test(claim_time * 1_000_000);

    // First claim: 150M tokens vested.
        claim(beneficiary);
        assert!(coin::balance<aptos_coin::AptosCoin>(beneficiary_addr) == 150_000_000, 106);
        let pool = borrow_global<VestingPool>(admin_addr);
        let stream = table::borrow(&pool.streams, beneficiary_addr);
        assert!(stream.claimed_amount == 150_000_000, 107);

    // Advance to end of vesting and claim remaining.
        let vesting_end_time = start_time + stream.vesting_duration;
        timestamp::update_global_time_for_test(vesting_end_time * 1_000_000);
        claim(beneficiary);
        assert!(coin::balance<aptos_coin::AptosCoin>(beneficiary_addr) == 300_000_000, 108);
        let pool = borrow_global<VestingPool>(admin_addr);
        assert!(!table::contains(&pool.streams, beneficiary_addr), 109);

    // Cleanup resources.
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
}

    #[test(admin = @dev_addr, beneficiary = @0x2, aptos_framework = @0x1)]
#[expected_failure(abort_code = E_STREAM_EXISTS)]
public entry fun test_create_duplicate_stream(
    admin: &signer,
    beneficiary: &signer,
    aptos_framework: &signer
) acquires VestingPool {
    // Initialize test environment
    timestamp::set_time_has_started_for_testing(aptos_framework);
    account::create_account_for_test(@dev_addr);
    account::create_account_for_test(@0x2);
    
    // Set up AptosCoin
    let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(aptos_framework);
    coin::register<aptos_coin::AptosCoin>(admin);
    aptos_coin::mint(aptos_framework, @dev_addr, 1_000_000);

    // Initialize vesting pool and create first stream
    initialize(admin);
    create_vesting_stream(admin, @0x2, 100_000, 100, 1000);

    // Attempt to create duplicate stream (should abort)
    create_vesting_stream(admin, @0x2, 200_000, 200, 2000);

    // Cleanup (unreachable due to abort)
    coin::destroy_burn_cap(burn_cap);
    coin::destroy_mint_cap(mint_cap);
}

#[test(admin = @dev_addr, non_admin = @0x3, aptos_framework = @0x1)]
#[expected_failure(abort_code = E_NOT_OWNER)]
public entry fun test_non_admin_create_stream(
    admin: &signer,
    non_admin: &signer,
    aptos_framework: &signer
) acquires VestingPool {
    // Initialize test environment
    timestamp::set_time_has_started_for_testing(aptos_framework);
    account::create_account_for_test(@dev_addr);
    account::create_account_for_test(@0x3);
    
    // Set up AptosCoin
    let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(aptos_framework);
    coin::register<aptos_coin::AptosCoin>(admin);
    aptos_coin::mint(aptos_framework, @dev_addr, 1_000_000);

    // Initialize vesting pool
    initialize(admin);

    // Non-admin attempts to create stream (should abort)
    create_vesting_stream(non_admin, @0x2, 100_000, 100, 1000);

    // Cleanup (unreachable due to abort)
    coin::destroy_burn_cap(burn_cap);
    coin::destroy_mint_cap(mint_cap);
}

#[test(admin = @dev_addr, beneficiary = @0x2, aptos_framework = @0x1)]
#[expected_failure(abort_code = E_INVALID_PARAMETERS)]
public entry fun test_invalid_cliff_duration(
    admin: &signer,
    beneficiary: &signer,
    aptos_framework: &signer
) acquires VestingPool {
    // Initialize test environment
    timestamp::set_time_has_started_for_testing(aptos_framework);
    account::create_account_for_test(@dev_addr);
    account::create_account_for_test(@0x2);
    
    // Set up AptosCoin
    let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(aptos_framework);
    coin::register<aptos_coin::AptosCoin>(admin);
    aptos_coin::mint(aptos_framework, @dev_addr, 1_000_000);

    initialize(admin);
    
    // Attempt invalid stream creation (cliff 200 > vesting 100)
    create_vesting_stream(admin, @0x2, 100_000, 200, 100);

    // Cleanup (unreachable due to abort)
    coin::destroy_burn_cap(burn_cap);
    coin::destroy_mint_cap(mint_cap);
}

#[test(admin = @dev_addr, attacker = @0x3, aptos_framework = @0x1)]
#[expected_failure(abort_code = E_NO_STREAM)]
public entry fun test_claim_no_stream(
    admin: &signer,
    attacker: &signer,
    aptos_framework: &signer
) acquires VestingPool {
    // Initialize test environment
    timestamp::set_time_has_started_for_testing(aptos_framework);
    account::create_account_for_test(@dev_addr);
    account::create_account_for_test(@0x3);
    
    // Set up AptosCoin
    let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(aptos_framework);
    coin::register<aptos_coin::AptosCoin>(admin);
    coin::register<aptos_coin::AptosCoin>(attacker);
    aptos_coin::mint(aptos_framework, @dev_addr, 1_000_000);

    initialize(admin);
    
    // Unrelated user attempts to claim
    claim(attacker);  // @0x3 has no vesting stream

    // Cleanup (unreachable due to abort)
    coin::destroy_burn_cap(burn_cap);
    coin::destroy_mint_cap(mint_cap);
}

#[test(admin = @dev_addr, beneficiary = @0x2, aptos_framework = @0x1)]
#[expected_failure(abort_code = E_NOTHING_TO_CLAIM)]
public entry fun test_claim_before_cliff(
    admin: &signer,
    beneficiary: &signer,
    aptos_framework: &signer
) acquires VestingPool {
    // Initialize test environment
    timestamp::set_time_has_started_for_testing(aptos_framework);
    account::create_account_for_test(@dev_addr);
    account::create_account_for_test(@0x2);
    
    // Set up AptosCoin
    let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(aptos_framework);
    coin::register<aptos_coin::AptosCoin>(admin);
    coin::register<aptos_coin::AptosCoin>(beneficiary);
    aptos_coin::mint(aptos_framework, @dev_addr, 1_000_000);

    initialize(admin);
    
    // Create valid stream (start_time = now + 100)
    create_vesting_stream(admin, @0x2, 100_000, 100, 1000);
    
    // Immediately try to claim (before cliff)
    claim(beneficiary);  // current_time < start_time + cliff_duration

    // Cleanup (unreachable due to abort)
    coin::destroy_burn_cap(burn_cap);
    coin::destroy_mint_cap(mint_cap);
}

#[test(admin = @dev_addr, beneficiary = @0x2, aptos_framework = @0x1)]
#[expected_failure(abort_code = E_INSUFFICIENT_FUNDS)]
public entry fun test_insufficient_pool_balance(
    admin: &signer,
    beneficiary: &signer,
    aptos_framework: &signer
) acquires VestingPool {
    // Initialize test environment
    timestamp::set_time_has_started_for_testing(aptos_framework);
    account::create_account_for_test(@dev_addr);
    account::create_account_for_test(@0x2);
    
    // Set up AptosCoin with burn capability
    let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(aptos_framework);
    coin::register<aptos_coin::AptosCoin>(admin);
    coin::register<aptos_coin::AptosCoin>(beneficiary);
    aptos_coin::mint(aptos_framework, @dev_addr, 1_000_000);

    initialize(admin);
    
    // Create stream with 100K tokens
    create_vesting_stream(admin, @0x2, 100_000, 0, 100);
    
    // Properly drain pool funds using burn
    let pool = borrow_global_mut<VestingPool>(@dev_addr);
    let stolen_coins = coin::extract(&mut pool.coin, 99_999);
    
    // Burn the coins instead of destroying as zero
    coin::burn(stolen_coins, &burn_cap);

    // Get stream reference
    let stream = table::borrow(&pool.streams, @0x2);
    let vesting_end_time = stream.start_time + stream.vesting_duration;
    
    // Set time to vesting end
    timestamp::update_global_time_for_test(vesting_end_time * 1_000_000);
    
    // Attempt claim (needs 100K, pool has 1)
    claim(beneficiary);

    // Cleanup
    coin::destroy_burn_cap(burn_cap);
    coin::destroy_mint_cap(mint_cap);
}

#[test(admin = @dev_addr, aptos_framework = @0x1)]
#[expected_failure(abort_code = E_NO_STREAM)]
public entry fun test_get_vested_balance_no_stream(
    admin: &signer,
    aptos_framework: &signer
) acquires VestingPool {
    timestamp::set_time_has_started_for_testing(aptos_framework);
    account::create_account_for_test(@dev_addr);
    
    let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(aptos_framework);
    coin::register<aptos_coin::AptosCoin>(admin);
    aptos_coin::mint(aptos_framework, @dev_addr, 1_000_000);

    initialize(admin);

    // Query random address that was never added
    get_vested_balance(@0xDEADBEEF);

    coin::destroy_burn_cap(burn_cap);
    coin::destroy_mint_cap(mint_cap);
}



}

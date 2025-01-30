// WIP
// Placeholder for a proper date parsing module

module ol_framework::date {
  use diem_framework::timestamp;

  friend ol_framework::lockbox;

  // Returns start of unix day in seconds, and the seconds since start of day
  public(friend) fun start_of_day_seconds(): (u64, u64) {
    let timestamp = timestamp::now_seconds();
    let since_start = timestamp % 86400;
    let start_of_day = timestamp - since_start;
    (start_of_day, since_start)
  }

  #[test(framework = @0x1)]
  fun test_day(framework: &signer) {
    // use diem_framework::debug::print;

    timestamp::set_time_has_started_for_testing(framework);
    let then = 1727122878 * 1000000;

    timestamp::update_global_time_for_test(then);
    let (a,b) = start_of_day_seconds();

    let now = 1727123437 * 1000000;
    timestamp::update_global_time_for_test(now);
    let (a_now, b_now) = start_of_day_seconds();
    assert!(a == a_now, 0);
    assert!(b != b_now, 1);
  }
}

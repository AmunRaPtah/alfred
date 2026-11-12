# Alfred eval: khermes (burst-qwen36-35b-kaggle), 2026-11-05 (partial -- interrupted)

Overall: 5/5 passed, suite wall time 2551.9s

## hard_code: 2/2
- [PASS] hard_ledger_bugs (401.0s, turns=22): HIDDEN_OK 6
- [PASS] hard_wordstat_feature (630.0s, turns=25): HIDDEN_OK 10

## hard_debug: 1/1
- [PASS] hard_syncd_debug (349.8s, turns=20): run.sh prints synced 74 records; 4 other host configs also correct

## hard_data: 2/2
- [PASS] hard_dispense_clean (474.5s, turns=6): all cleaned statistics match
- [PASS] hard_pk_nca (660.4s, turns=15): all NCA parameters within 0.5%

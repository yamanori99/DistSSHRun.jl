category: breaking

- `drive` and `collect!` refuse a collect root that is the project root or a parent of it. That includes `DISTRIBUTED_COLLECT_DIRS=.` and a default root from `DISTRIBUTED_OUTPUT_DIR`. Point collect at a result directory inside the project. 0.1.7 warned and still collected. The check runs when sentinels are placed and again in `collect!` / `drive --collect-missing` / `drive --collect-overwrite`.

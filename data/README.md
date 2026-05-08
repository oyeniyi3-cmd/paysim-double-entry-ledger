# paysim-double-entry-ledger
Double-entry financial ledger system built in PostgreSQL using the PaySim synthetic payments dataset. Demonstrates schema design, ETL pipelines, and SQL analytics.


## Dataset

This project uses the **PaySim** synthetic mobile money transactions dataset, 
which simulates fraudulent transactions based on real-world financial logs. 
The dataset is not included in this repository due to its size (~470 MB, ~6.3 million rows) 
and to keep the repo focused on code.

### Downloading the data

1. Download `PS_20174392719_1491204439457_log.csv` from Kaggle:  
   https://www.kaggle.com/datasets/ealaxi/paysim1

2. Place the file in a `data/` directory at the root of the paysim-double-entry-ledger project.
3. The `data/` directory is gitignored, so the CSV will not be committed.

### Loading into PostgreSQL

After downloading, load the CSV into the `paysim_raw` staging table 
(see `sql/schema/ledger_platform_master_ddl.sql` for the table definition):

```sql
\COPY paysim_raw FROM 'data/PS_20174392719_1491204439457_log.csv' 
  WITH (FORMAT csv, HEADER true);
```

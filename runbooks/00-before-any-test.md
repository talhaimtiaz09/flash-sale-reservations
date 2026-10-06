# Before any load test

Every runbook starts from here. Results are filled in only from a real run,
including runs that miss.

## Apply the lab

```bash
cd terraform/envs/lab
terraform init -backend-config="bucket=<state_bucket>"
TF_VAR_alarm_email=you@example.com terraform apply
export API=$(terraform output -raw api_url)
export TABLE=$(terraform output -raw table_name)
cd -
```

Confirm the SNS subscription email. Open the dashboard (`terraform output
dashboard_url`) in another tab.

## Check the account's limits

```bash
aws lambda get-account-settings --query 'AccountLimit'
aws service-quotas list-service-quotas --service-code apigateway \
  --query "Quotas[?contains(QuotaName, 'Throttle')].[QuotaName,Value]" --output table
```

Write the Lambda concurrency limit and API Gateway's account throttle in the
runbook. If Lambda concurrency is 10, the burst and
hot-key tests measure the account limit, not the design; ask for an increase
first and say so in the results.

## Note the bill

Cost Explorer lags by about a day. Note the date of the run and read the
day's cost for DynamoDB, Lambda, API Gateway and CloudWatch the next day.

## After the session

```bash
cd terraform/envs/lab && TF_VAR_alarm_email=you@example.com terraform destroy
```

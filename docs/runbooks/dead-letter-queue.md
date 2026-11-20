# Runbook: messages in the dead-letter queue

The worker gave up after five attempts. Delivery is at-least-once and the worker is idempotent, so a redrive is safe **once the cause is fixed**.

1. **Inspect without consuming.** Peek a sample with a short visibility timeout:
   ```bash
   aws sqs receive-message --queue-url <dlq-url> --max-number-of-messages 5 --visibility-timeout 30 \
     --attribute-names All --message-attribute-names All
   ```
2. **Classify:** bad payload (poison), downstream outage, or a bug.
   - For a bad payload, fix the producer, then delete or archive those messages.
3. **Redrive** after the fix ships:
   ```bash
   aws sqs start-message-move-task --source-arn <dlq-arn> --max-number-of-messages-per-second 50
   ```
   Throttle the redrive so it doesn't overload the database or third parties.
4. **Confirm** that `ApproximateNumberOfMessagesVisible` on the DLQ drains, and that the alarm returns to OK.

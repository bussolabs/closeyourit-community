class AddDigestBucketToAlertingNotifications < ActiveRecord::Migration[8.1]
  def change
    # Bucket di raccolta digest stampato sulla riga al dispatch: nil = consegna immediata (o in-app);
    # daily/weekly = notifica trattenuta (status :queued) che il job digest raccoglie e riepiloga.
    # L'indice parziale serve al job digest (WHERE status=queued) a raggruppare per canale+bucket.
    add_column :alerting_notifications, :digest_bucket, :integer

    add_index :alerting_notifications, %i[via digest_bucket],
              where: "status = 4",
              name: "idx_alerting_notifications_digest_queue"
  end
end

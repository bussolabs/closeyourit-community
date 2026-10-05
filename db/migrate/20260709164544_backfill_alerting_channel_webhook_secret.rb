class BackfillAlertingChannelWebhookSecret < ActiveRecord::Migration[8.1]
  # Sposta il secret webhook dal config JSONB (plaintext) alla colonna cifrata `webhook_secret`.
  # Richiede AR_ENCRYPTION_* (config/application.rb) — al deploy le chiavi arrivano dal bootstrap gestito.
  # save!(validate: false): un URL diventato interno nel frattempo non deve bloccare il backfill.
  def up
    Alerting::Channel.reset_column_information
    Alerting::Channel.find_each do |channel|
      secret = channel.config["secret"]
      next if secret.blank?

      channel.webhook_secret = secret
      channel.config = channel.config.except("secret")
      channel.save!(validate: false)
    end
  end

  def down
    Alerting::Channel.reset_column_information
    Alerting::Channel.find_each do |channel|
      next if channel.webhook_secret.blank?

      channel.config = channel.config.merge("secret" => channel.webhook_secret)
      channel.save!(validate: false)
    end
  end
end

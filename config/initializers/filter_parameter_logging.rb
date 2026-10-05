# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
#
# I vault dei segreti (progetto, condiviso, personale — web e CLI) portano i valori sotto tre soli nomi:
# `value` (secret singolo), `values` (matrice nome×ambiente del form web) e `variables` (import in blocco
# da CLI). Il match è per SOTTOSTRINGA, quindi `:value` copre anche `values` e le chiavi `value` annidate
# negli elementi di `variables`; `:variables` maschera per intero l'array dell'import. Senza queste voci
# i valori finiscono in chiaro nei log a ogni salvataggio (CYRA-203). Spec: filter_parameter_logging_spec.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  :value, :values, :variables, :code, :state
]

# Worker payloads contain private conversations and memory.
Rails.application.config.filter_parameters += [ :events, :lease_id ]

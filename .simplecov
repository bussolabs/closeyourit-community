# Politica di copertura in un posto solo: lib/simplecov_configuration.rb (CYRA-551).
#
# In sintesi: obbligatoria nei controlli automatici, dove è il gate ≥90 linee/branch; in locale
# soltanto quando la si chiede con COVERAGE=1, perché il tracking più il report costano una decina
# di secondi a OGNI run, anche a un singolo file. Il gate vero e proprio resta legato a
# COVERAGE_ENFORCE: i run di subset (es. job e2e-system, che gira solo spec/system) impostano
# CI=true ma non COVERAGE_ENFORCE, e non devono far fallire la soglia.
#
# CYRA-550 — qui dentro ci va SOLO configurazione. L'avvio del tracking sta in spec/spec_helper.rb:
# da simplecov 1.0 un `SimpleCov.start` chiamato da questo file è deprecato e in una prossima
# versione non avvierà più niente, in silenzio.
require_relative "lib/simplecov_configuration"

SimplecovConfiguration.configure!

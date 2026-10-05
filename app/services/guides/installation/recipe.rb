# frozen_string_literal: true

module Guides
  module Installation
    class Recipe < ApplicationService
      def initialize(observation:)
        @observation = observation
      end

      def call
        integration = @observation.dig("tuple", "integration")
        return php if integration.start_with?("php-laravel-")
        recipe = recipes.fetch(integration) { raise Invalid, "No installation recipe for this observation" }
        recipe[:install] = checksum + recipe[:install] if @observation.dig("tuple", "package", "origin") == "local_candidate"
        recipe
      end

      private

      def recipes
        {
          "ruby-native" => { language: "ruby", install: 'gem install --local "$CLOSEYOURIT_SDK_ARTIFACT"', code: <<~'CODE' },
            require "closeyourit-ruby"
            CloseYourIt.init do |config|
              config.endpoint_url = ENV.fetch("CLOSEYOURIT_ENDPOINT_URL")
              config.project_id = ENV.fetch("CLOSEYOURIT_PROJECT_ID")
              config.token = ENV.fetch("CLOSEYOURIT_TOKEN")
              config.environment = ENV.fetch("CLOSEYOURIT_ENVIRONMENT")
              config.release = ENV.fetch("CLOSEYOURIT_RELEASE")
            end
            result = CloseYourIt.capture_message("Installation check")
            event_id = result && result["event_id"]
            CloseYourIt.shutdown
            puts event_id if event_id
          CODE
          "python-native" => { language: "python", install: 'python -m pip install "$CLOSEYOURIT_SDK_ARTIFACT"', code: <<~'CODE' },
            from closeyourit import Client, Configuration
            # Configuration reads CLOSEYOURIT_ENDPOINT_URL, PROJECT_ID,
            # TOKEN, ENVIRONMENT and RELEASE from the process environment.
            client = Client(Configuration())
            event_id = client.capture_message("Installation check")
            client.close(timeout=15)
            if event_id:
                print(event_id)
          CODE
          "node-native" => { language: "javascript", install: 'npm install "$CLOSEYOURIT_SDK_ARTIFACT"', code: <<~'CODE' },
            import * as CloseYourIt from '@bussolabs/closeyourit-js';
            let eventId;
            CloseYourIt.init({
              endpointUrl: process.env.CLOSEYOURIT_ENDPOINT_URL,
              projectId: process.env.CLOSEYOURIT_PROJECT_ID,
              token: process.env.CLOSEYOURIT_TOKEN,
              environment: process.env.CLOSEYOURIT_ENVIRONMENT,
              release: process.env.CLOSEYOURIT_RELEASE,
              autoInstall: false,
              beforeSend(event) { eventId = event.event_id; return event; },
            });
            CloseYourIt.captureMessage('Installation check');
            await CloseYourIt.close();
            if (eventId) console.log(eventId);
          CODE
          "sentry-python" => { language: "python", install: "python -m pip install \"sentry-sdk==#{@observation.dig('tuple', 'package', 'version')}\"", code: <<~'CODE' },
            import os
            import sentry_sdk
            sentry_sdk.init(
                dsn=os.environ["SENTRY_DSN"],
                environment=os.environ["CLOSEYOURIT_ENVIRONMENT"],
                release=os.environ["CLOSEYOURIT_RELEASE"],
                send_default_pii=False,
                traces_sample_rate=0,
                auto_session_tracking=False,
            )
            event_id = sentry_sdk.capture_message("Installation check")
            sentry_sdk.flush(timeout=15)
            if event_id:
                print(event_id)
          CODE
          "sentry-node" => { language: "javascript", install: "npm install --save-exact @sentry/node@#{@observation.dig('tuple', 'package', 'version')}", code: <<~'CODE' }
            import * as Sentry from '@sentry/node';
            Sentry.init({
              dsn: process.env.SENTRY_DSN,
              environment: process.env.CLOSEYOURIT_ENVIRONMENT,
              release: process.env.CLOSEYOURIT_RELEASE,
              defaultIntegrations: false,
              dataCollection: {
                userInfo: false, cookies: false, httpHeaders: false, httpBodies: [],
                urlQueryParams: false, graphQL: { document: false, variables: false },
                genAI: { inputs: false, outputs: false }, databaseQueryData: false,
                queues: false, stackFrameVariables: false, frameContextLines: 0,
              },
              tracesSampleRate: 0,
            });
            const eventId = Sentry.captureMessage('Installation check');
            await Sentry.close(15000);
            console.log(eventId);
          CODE
        }
      end

      def php
        recipe = { language: "php", install: <<~'INSTALL', code: <<~'CODE' }
          # Read package metadata from the exact verified TAR. No ZIP extension is needed.
          composer config --json repositories.closeyourit "$(php -r '$path=realpath($argv[1]);$tar=new PharData($path);$package=json_decode($tar["composer.json"]->getContent(),true,512,JSON_THROW_ON_ERROR);$package["dist"]=["type"=>"tar","url"=>"file://".str_replace("%2F","/",rawurlencode($path)),"shasum"=>hash_file("sha1",$path),"reference"=>"SOURCE_COMMIT"];echo json_encode(["type"=>"package","package"=>$package],JSON_UNESCAPED_SLASHES|JSON_THROW_ON_ERROR);' "$CLOSEYOURIT_SDK_ARTIFACT")"
          # Merge the discovery exclusion, preserving existing exclusions.
          php -r '$p="composer.json";$c=json_decode(file_get_contents($p),true,512,JSON_THROW_ON_ERROR);$d=$c["extra"]["laravel"]["dont-discover"]??[];$c["extra"]["laravel"]["dont-discover"]=array_values(array_unique([...$d,"sentry/sentry-laravel"]));file_put_contents($p,json_encode($c,JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES|JSON_THROW_ON_ERROR).PHP_EOL);'
          composer require bussolabs/closeyourit-laravel:0.1.0 --no-scripts
          # After applying the pre-autoload bootstrap below to every entrypoint:
          php artisan package:discover
        INSTALL
          use CloseYourIt\Laravel\Runtime;
          use CloseYourIt\Laravel\ServiceProvider;
          use Illuminate\Foundation\Application;
          use Illuminate\Foundation\Configuration\Exceptions;
          use Sentry\Laravel\Integration;

          require __DIR__ . '/../vendor/bussolabs/closeyourit-laravel/bootstrap.php';
          require __DIR__ . '/../vendor/autoload.php';
          // Supply enabled:boolean, endpoint, token, dsn, service,
          // environment and release from the authorized runtime vault.
          // Both token and dsn must belong to the same project.
          $telemetry = Runtime::start($trustedRuntimeConfiguration);
          $app = Application::configure(basePath: dirname(__DIR__))
              ->withProviders([ServiceProvider::class])
              ->withExceptions(function (Exceptions $exceptions) use ($telemetry): void {
                  if ($telemetry->active()) {
                      Integration::handles($exceptions);
                  }
              })
              ->create();
          $app->instance(Runtime::class, $telemetry);
          return $app;
        CODE
        recipe[:install] = "set -eu\n" + checksum + recipe[:install].sub("SOURCE_COMMIT", @observation.dig("tuple", "package", "source", "commit"))
        recipe[:capture] = php_capture
        recipe
      end

      def checksum
        "printf '%s  %s\\n' '#{@observation.dig("tuple", "package", "sha256")}' \"$CLOSEYOURIT_SDK_ARTIFACT\" | shasum -a 256 -c - || exit 1\n"
      end

      def php_capture
        return <<~'PHP' if @observation.dig("tuple", "integration") == "php-laravel-otlp"
          // Run inside an actual instrumented HTTP request.
          $context = \OpenTelemetry\API\Trace\Span::getCurrent()->getContext();
          if (!$context->isValid()) {
              throw new \RuntimeException("No active instrumented request span");
          }
          echo json_encode(["trace_id" => $context->getTraceId(), "span_id" => $context->getSpanId()], JSON_THROW_ON_ERROR);
          // Wait for request termination before checking the receipt.
        PHP
        <<~'PHP'
          // Do not recapture an exception already handled by Laravel.
          $eventId = \Sentry\captureMessage("Installation check");
          \Sentry\flush();
          if ($eventId !== null) {
              echo (string) $eventId;
          }
        PHP
      end
    end
  end
end

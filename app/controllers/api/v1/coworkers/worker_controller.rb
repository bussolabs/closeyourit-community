module Api
  module V1
    module Coworkers
      class WorkerController < Api::BaseController
        before_action :authenticate_worker

        def readiness
          render_ok({ protocol: "coworkers-worker/v1" })
        end

        def claim
          run = ::Coworkers::Worker.claim
          render_ok(run && { id: run.id, lease_id: run.worker_lease_id, kind: run.kind, prompt: run.context.to_json })
        end

        def events
          raise ::Coworkers::Worker::InvalidEvent if request.raw_post.bytesize > 262144
          batch = params[:events]
          raise ::Coworkers::Worker::InvalidEvent unless batch.is_a?(Array) && batch.all? { |event| event.is_a?(ActionController::Parameters) }
          result = ::Coworkers::Worker.report(id: params[:run_id], lease_id: params[:lease_id],
            sequence: params[:sequence], events: batch.map(&:to_unsafe_h))
          render_ok(result)
        rescue ::Coworkers::Worker::StaleLease
          render_error("R409-COWORKERS-001", "Worker lease or sequence is no longer valid", status: :conflict)
        rescue ::Coworkers::Worker::InvalidEvent, ActiveRecord::RecordInvalid
          render_error("R422-COWORKERS-001", "Invalid worker event batch", status: :unprocessable_content)
        end

        def tools
          input = params[:input].respond_to?(:to_unsafe_h) ? params[:input].to_unsafe_h : {}
          result = ::Coworkers::Worker.call_tool(id: params[:run_id], lease_id: params[:lease_id],
            call_id: params[:call_id], name: params[:name], input: input)
          render_ok({ result: result })
        rescue ::Coworkers::Worker::StaleLease
          render_error("R409-COWORKERS-001", "Worker lease or sequence is no longer valid", status: :conflict)
        rescue ::Coworkers::Worker::InvalidEvent
          render_error("R422-COWORKERS-002", "Invalid tool call", status: :unprocessable_content)
        end

        def session
          args = params[:args].respond_to?(:to_unsafe_h) ? params[:args].to_unsafe_h : {}
          result = ::Coworkers::Worker.session(id: params[:run_id], lease_id: params[:lease_id], op: params[:op], args: args)
          render_ok({ result: result })
        rescue ::Coworkers::Worker::StaleLease
          render_error("R409-COWORKERS-001", "Worker lease or sequence is no longer valid", status: :conflict)
        rescue ::Coworkers::Worker::InvalidEvent
          render_error("R422-COWORKERS-004", "Invalid session call", status: :unprocessable_content)
        end

        private

        def authenticate_worker
          return head :not_found unless ::Coworkers.enabled? && ::Coworkers.remote?
          expected = ::Coworkers.worker_token_digest
          supplied = request.authorization.to_s.delete_prefix("Bearer ")
          valid = expected.match?(/\A[a-f0-9]{64}\z/) && request.authorization.to_s.start_with?("Bearer ") &&
            supplied.bytesize.between?(32, 512) && ActiveSupport::SecurityUtils.secure_compare(expected, Digest::SHA256.hexdigest(supplied))
          return head :unauthorized unless valid
          organization = Organizations::Organization.find_by(id: ::Coworkers.worker_organization_id)
          head :forbidden if organization.nil? || organization.suspended?
        end
      end
    end
  end
end

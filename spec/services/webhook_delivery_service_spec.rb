# frozen_string_literal: true

require "rails_helper"

RSpec.describe WebhookDeliveryService do
  let(:server) { create(:server) }
  let(:webhook) { create(:webhook, server: server) }
  let(:webhook_request) { create(:webhook_request, :locked, webhook: webhook) }

  subject(:service) { described_class.new(webhook_request: webhook_request) }

  let(:response_status) { 200 }
  let(:response_body) { "OK" }

  before do
    stub_request(:post, webhook.url).to_return(status: response_status, body: response_body)
  end

  describe "#call" do
    context "with postal output style" do
      it "sends a request to the webhook's url with postal format" do
        service.call
        expect(WebMock).to have_requested(:post, webhook.url).with({
          body: {
            event: webhook_request.event,
            timestamp: webhook_request.created_at.to_f,
            payload: webhook_request.payload,
            uuid: webhook_request.uuid
          }.to_json,
          headers: {
            "Content-Type" => "application/json",
            "X-Postal-Signature" => /\A[a-z0-9\/+]+=*\z/i,
            "X-Postal-Signature-256" => /\A[a-z0-9\/+]+=*\z/i,
            "X-Postal-Signature-KID" => /\A[a-f0-9\/+]{64}\z/i
          }
        })
      end
    end

    context "with listmonk output style" do
      let(:webhook) { create(:webhook, server: server, output_style: "listmonk") }

      context "for MessageBounced event" do
        let(:webhook_request) do
          create(:webhook_request, :locked, webhook: webhook, event: "MessageBounced", payload: {
            bounce: { bounce_type: "hard" },
            original_message: { to: "test@example.com" }
          })
        end

        it "sends a request with listmonk bounce format" do
          service.call
          expect(WebMock).to have_requested(:post, webhook.url).with({
            body: {
              email: "test@example.com",
              source: "postal",
              type: "hard"
            }.to_json,
            headers: {
              "Content-Type" => "application/json",
              "X-Postal-Signature" => /\A[a-z0-9\/+]+=*\z/i,
              "X-Postal-Signature-256" => /\A[a-z0-9\/+]+=*\z/i,
              "X-Postal-Signature-KID" => /\A[a-f0-9\/+]{64}\z/i
            }
          })
        end

        context "with soft bounce" do
          let(:webhook_request) do
            create(:webhook_request, :locked, webhook: webhook, event: "MessageBounced", payload: {
              bounce: { bounce_type: "soft" },
              original_message: { to: "soft-bounce@example.com" }
            })
          end

          it "sends a request with type 'soft'" do
            service.call
            expect(WebMock).to have_requested(:post, webhook.url).with({
              body: {
                email: "soft-bounce@example.com",
                source: "postal",
                type: "soft"
              }.to_json,
              headers: {
                "Content-Type" => "application/json",
                "X-Postal-Signature" => /\A[a-z0-9\/+]+=*\z/i,
                "X-Postal-Signature-256" => /\A[a-z0-9\/+]+=*\z/i,
                "X-Postal-Signature-KID" => /\A[a-f0-9\/+]{64}\z/i
              }
            })
          end
        end

        context "with string keys in payload" do
          let(:webhook_request) do
            create(:webhook_request, :locked, webhook: webhook, event: "MessageBounced", payload: {
              "bounce" => { "bounce_type" => "hard" },
              "original_message" => { "to" => "string-keys@example.com" }
            })
          end

          it "handles string keys correctly" do
            service.call
            expect(WebMock).to have_requested(:post, webhook.url).with({
              body: {
                email: "string-keys@example.com",
                source: "postal",
                type: "hard"
              }.to_json,
              headers: {
                "Content-Type" => "application/json",
                "X-Postal-Signature" => /\A[a-z0-9\/+]+=*\z/i,
                "X-Postal-Signature-256" => /\A[a-z0-9\/+]+=*\z/i,
                "X-Postal-Signature-KID" => /\A[a-f0-9\/+]{64}\z/i
              }
            })
          end
        end

        context "with unknown bounce type" do
          let(:webhook_request) do
            create(:webhook_request, :locked, webhook: webhook, event: "MessageBounced", payload: {
              bounce: { bounce_type: "unknown" },
              original_message: { to: "unknown-bounce@example.com" }
            })
          end

          it "defaults to 'hard' type for unknown bounce types" do
            service.call
            expect(WebMock).to have_requested(:post, webhook.url).with({
              body: {
                email: "unknown-bounce@example.com",
                source: "postal",
                type: "hard"
              }.to_json,
              headers: {
                "Content-Type" => "application/json",
                "X-Postal-Signature" => /\A[a-z0-9\/+]+=*\z/i,
                "X-Postal-Signature-256" => /\A[a-z0-9\/+]+=*\z/i,
                "X-Postal-Signature-KID" => /\A[a-f0-9\/+]{64}\z/i
              }
            })
          end
        end
      end

      context "for unsupported event" do
        let(:webhook_request) do
          create(:webhook_request, :locked, webhook: webhook, event: "UnsupportedEvent", payload: {})
        end

        it "raises an error for unsupported events" do
          expect { service.call }.to raise_error(Postal::Error, "Unsupported event 'UnsupportedEvent' for output style 'listmonk'")
        end

        it "does not send a request" do
          expect { service.call }.to raise_error(Postal::Error)
          expect(WebMock).not_to have_requested(:post, webhook.url)
        end

        it "does not create any webhook records" do
          expect { service.call }.to raise_error(Postal::Error)
          expect(server.message_db.webhooks.list(1)[:total]).to eq(0)
        end

        it "does not delete the webhook request" do
          expect { service.call }.to raise_error(Postal::Error)
          expect { webhook_request.reload }.not_to raise_error
        end
      end
    end

    it "sends a request to the webhook's url" do
      service.call
      expect(WebMock).to have_requested(:post, webhook.url).with({
        body: {
          event: webhook_request.event,
          timestamp: webhook_request.created_at.to_f,
          payload: webhook_request.payload,
          uuid: webhook_request.uuid
        }.to_json,
        headers: {
          "Content-Type" => "application/json",
          "X-Postal-Signature" => /\A[a-z0-9\/+]+=*\z/i,
          "X-Postal-Signature-256" => /\A[a-z0-9\/+]+=*\z/i,
          "X-Postal-Signature-KID" => /\A[a-f0-9\/+]{64}\z/i
        }
      })
    end

    context "when the endpoint returns a 200 OK" do
      it "creates a webhook request for the server" do
        service.call
        expect(server.message_db.webhooks.list(1)[:total]).to eq(1)
        webhook_request = server.message_db.webhooks.list(1)[:records].first
        expect(webhook_request).to have_attributes(
          event: webhook_request.event,
          url: webhook_request.url,
          status_code: 200,
          body: "OK",
          uuid: webhook_request.uuid,
          will_retry?: false,
          payload: webhook_request.payload,
          attempt: 1,
          timestamp: webhook_request.timestamp
        )
      end

      it "deletes the webhook request" do
        service.call
        expect { webhook_request.reload }.to raise_error(ActiveRecord::RecordNotFound)
      end

      it "updates the last used at time on the webhook" do
        service.call
        expect(webhook.reload.last_used_at).to be_within(1.second).of(Time.current)
      end
    end

    context "when the request returns a 500 Internal Server Error for the first time" do
      let(:response_status) { 500 }
      let(:response_body) { "internal server error!" }

      it "unlocks the webhook request if locked" do
        expect { service.call }.to change { webhook_request.reload.locked? }.from(true).to(false)
      end

      it "updates the retry time and attempt counter" do
        service.call
        expect(webhook_request.reload.attempts).to eq(1)
        expect(webhook_request.retry_after).to be_within(1.second).of(2.minutes.from_now)
      end
    end

    context "when the request returns a 500 Internal Server Error for the second time" do
      let(:webhook_request) { create(:webhook_request, :locked, webhook: webhook, attempts: 1) }
      let(:response_status) { 500 }
      let(:response_body) { "internal server error!" }

      it "updates the retry time and attempt counter" do
        service.call
        expect(webhook_request.reload.attempts).to eq(2)
        expect(webhook_request.retry_after).to be_within(1.second).of(3.minutes.from_now)
      end
    end

    context "when the request returns a 500 Internal Server Error for the sixth time" do
      let(:webhook_request) { create(:webhook_request, :locked, webhook: webhook, attempts: 5) }
      let(:response_status) { 500 }
      let(:response_body) { "internal server error!" }

      it "creates a webhook request for the server" do
        service.call
        expect(server.message_db.webhooks.list(1)[:total]).to eq(1)
        webhook_request = server.message_db.webhooks.list(1)[:records].first
        expect(webhook_request).to have_attributes(
          status_code: 500,
          body: "internal server error!",
          will_retry?: false,
          attempt: 6
        )
      end

      it "deletes the webhook request" do
        service.call
        expect { webhook_request.reload }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end
end

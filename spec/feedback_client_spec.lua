local cjson = require("cjson")
local FeedbackClient = require("core.lib.FeedbackClient")
local MockBackend = require("core.test.MockBackend")

describe("FeedbackClient", function()
	it("posts structured feedback through the reusable transport seam", function()
		local transport = MockBackend.transport({
			responses = {
				{ code = 201, body = '{"feedback_id":42,"created":true}' },
			},
		})

		local result = assert(FeedbackClient.submit("http://backend.test:8000", {
			client_feedback_id = "72c03f38-6553-4f0a-aa8f-a325e10e61c9",
			message = "Queue feedback",
			windows_user = "qa-user",
		}, {
			transport = transport,
			user_agent = "Lunar/test",
		}))

		assert.are.equal(42, result.feedback_id)
		assert.are.equal(1, #transport.requests)
		assert.are.equal("http://backend.test:8000/feedback", transport.requests[1].url)
		assert.are.equal("Lunar/test", transport.requests[1].headers["User-Agent"])
		local posted = cjson.decode(transport.requests[1].source())
		assert.are.equal("qa-user", posted.windows_user)
	end)

	it("surfaces API validation errors", function()
		local transport = MockBackend.transport({
			responses = {
				{ code = 422, status = "422 Unprocessable Entity", body = '{"detail":"invalid feedback"}' },
			},
		})

		local result, err = FeedbackClient.submit("http://backend.test:8000", {
			message = "",
		}, { transport = transport })

		assert.is_nil(result)
		assert.matches("invalid feedback", err)
	end)
end)

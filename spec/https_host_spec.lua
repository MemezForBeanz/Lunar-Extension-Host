local https = require("core.lib.https")

-- Minimal stand-in for a LuaSec X.509 object.
local function cert(san, cn)
	return {
		extensions = function()
			if not san then return {} end
			return { ["2.5.29.17"] = san }
		end,
		subject = function()
			return cn and { { oid = "2.5.4.3", name = "commonName", value = cn } } or {}
		end,
	}
end

describe("core.lib.https certificate_matches", function()
	it("matches an exact DNS name, case-insensitively", function()
		local c = cert({ dNSName = { "lunar.example.com" } })
		assert.is_true(https.certificate_matches(c, "LUNAR.example.com"))
		assert.is_false(https.certificate_matches(c, "other.example.com"))
	end)

	it("lets a wildcard cover exactly one left-most label", function()
		local c = cert({ dNSName = { "*.example.com" } })
		assert.is_true(https.certificate_matches(c, "api.example.com"))
		assert.is_false(https.certificate_matches(c, "example.com"))
		assert.is_false(https.certificate_matches(c, "a.b.example.com"))
		assert.is_false(https.certificate_matches(c, "api.example.com.evil.net"))
	end)

	it("never lets a wildcard cover a bare suffix or an IP", function()
		assert.is_false(https.certificate_matches(cert({ dNSName = { "*.com" } }), "example.com"))
		assert.is_false(https.certificate_matches(cert({ dNSName = { "*.0.0.1" } }), "127.0.0.1"))
	end)

	it("matches IP addresses only against iPAddress entries", function()
		local c = cert({ dNSName = { "10.20.30.40" }, iPAddress = { "10.0.0.5" } })
		assert.is_true(https.certificate_matches(c, "10.0.0.5."))
		assert.is_true(https.certificate_matches(c, "10.0.0.5"))
		assert.is_false(https.certificate_matches(c, "10.20.30.40"))
	end)

	it("matches IPv6 addresses in any spelling against iPAddress entries", function()
		local c = cert({ iPAddress = { "2001:db8::1" } })
		assert.is_true(https.certificate_matches(c, "[2001:DB8:0:0:0:0:0:1]"))
		assert.is_true(https.certificate_matches(c, "2001:db8::0:1"))
		assert.is_false(https.certificate_matches(c, "2001:db8::2"))
		assert.is_true(https.certificate_matches(cert({ iPAddress = { "::ffff:10.0.0.5" } }), "::ffff:a00:5"))
	end)

	it("treats a trailing dot as the same host and never lets an IP match a DNS entry", function()
		assert.is_true(https.certificate_matches(cert({ dNSName = { "example.com" } }), "example.com."))
		assert.is_false(https.certificate_matches(cert({ dNSName = { "127.0.0.1" } }), "127.0.0.1."))
		assert.is_false(https.certificate_matches(cert({ dNSName = { "127.0.0.1" } }), "127.0.0.1"))
	end)

	it("ignores the common name when subjectAltName is present", function()
		local c = cert({ dNSName = { "a.example.com" } }, "b.example.com")
		assert.is_false(https.certificate_matches(c, "b.example.com"))
	end)

	it("falls back to the common name only without subjectAltName", function()
		assert.is_true(https.certificate_matches(cert(nil, "legacy.example.com"), "legacy.example.com"))
		assert.is_false(https.certificate_matches(cert(nil, "legacy.example.com"), "x.example.com"))
	end)

	it("rejects a missing certificate or host", function()
		assert.is_false(https.certificate_matches(nil, "example.com"))
		assert.is_false(https.certificate_matches(cert({ dNSName = { "example.com" } }), ""))
	end)
end)

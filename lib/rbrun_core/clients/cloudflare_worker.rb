# frozen_string_literal: true

module RbrunCore
  module Clients
    # Worker script generation for Cloudflare Workers.
    module CloudflareWorker
      class << self
        def script
          cookie_name = Naming.auth_cookie
          <<~JS
            export default {
              async fetch(request, env) {
                const url = new URL(request.url);
                const cookies = parseCookies(request.headers.get('Cookie') || '');
                const tokenParam = url.searchParams.get('token');
                const cookieToken = cookies['#{cookie_name}'];

                const token = tokenParam || cookieToken;
                if (!token || token !== env.ACCESS_TOKEN) {
                  return new Response('Not Found', { status: 404 });
                }

                if (tokenParam && !cookieToken) {
                  url.searchParams.delete('token');
                  return new Response(null, {
                    status: 302,
                    headers: {
                      'Location': url.toString(),
                      'Set-Cookie': `#{cookie_name}=${token}; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=86400`
                    }
                  });
                }

                return fetch(request);
              }
            };

            function parseCookies(cookieHeader) {
              const cookies = {};
              if (!cookieHeader) return cookies;
              cookieHeader.split(';').forEach(cookie => {
                const [name, ...rest] = cookie.trim().split('=');
                if (name) cookies[name] = rest.join('=');
              });
              return cookies;
            }
          JS
        end

        def generate(slug:, access_token:, target_url: nil)
          script
        end

        def bindings(slug, access_token, ws_url: nil, api_url: nil)
          [
            { type: "plain_text", name: "ACCESS_TOKEN", text: access_token },
            { type: "plain_text", name: "SANDBOX_SLUG", text: slug.to_s },
            { type: "plain_text", name: "WS_URL", text: ws_url || "" },
            { type: "plain_text", name: "API_URL", text: api_url || "" }
          ]
        end

        def build_multipart(boundary, metadata, script_content)
          parts = []
          parts << "--#{boundary}\r\n"
          parts << "Content-Disposition: form-data; name=\"metadata\"\r\n"
          parts << "Content-Type: application/json\r\n\r\n"
          parts << metadata.to_json
          parts << "\r\n--#{boundary}\r\n"
          parts << "Content-Disposition: form-data; name=\"worker.js\"; filename=\"worker.js\"\r\n"
          parts << "Content-Type: application/javascript+module\r\n\r\n"
          parts << script_content
          parts << "\r\n--#{boundary}--\r\n"
          parts.join
        end
      end
    end
  end
end

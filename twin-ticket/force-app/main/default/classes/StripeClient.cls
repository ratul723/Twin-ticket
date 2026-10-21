/**
 * All Stripe calls go through the Named Credential 'Stripe_API'. The secret key lives only in the External Credential:
 * this class never sees, builds or logs it. One automatic retry on network failure or a 5xx. That is safe because
 * POSTs that create things carry an Idempotency-Key.
 */
public without sharing class StripeClient {

    public class StripeResponse {
        public Integer status;
        public Map<String, Object> body = new Map<String, Object>();
        public String errorType;
        public String errorCode;
        public Boolean transportFailure = false;
        public Boolean ok() { return !transportFailure && status != null && status >= 200 && status < 300; }
    }

    private static final String LOG = 'TT-STRIPE ';
    private static final String BASE = 'callout:Stripe_API';
    private static final Integer TIMEOUT_MS = 20000;

    public static StripeResponse createCheckoutSession(Map<String, String> params, String idempotencyKey) {
        return send('POST', '/v1/checkout/sessions', params, idempotencyKey);
    }

    public static StripeResponse getCheckoutSession(String sessionId) {
        return send('GET', '/v1/checkout/sessions/' + EncodingUtil.urlEncode(sessionId, 'UTF-8'), null, null);
    }

    public static StripeResponse expireCheckoutSession(String sessionId) {
        return send('POST', '/v1/checkout/sessions/' + EncodingUtil.urlEncode(sessionId, 'UTF-8') + '/expire',
            new Map<String, String>(), null);
    }

    private static StripeResponse send(String method, String path, Map<String, String> params, String idemKey) {
        StripeResponse r;
        for (Integer attempt = 1; attempt <= 2; attempt++) {
            r = sendOnce(method, path, params, idemKey);
            Boolean retryable = r.transportFailure || (r.status != null && r.status >= 500);
            if (!retryable) { break; }
            System.debug(LoggingLevel.WARN, LOG + method + ' ' + path + ' attempt ' + attempt + ' failed, status=' + r.status);
        }
        return r;
    }

    private static StripeResponse sendOnce(String method, String path, Map<String, String> params, String idemKey) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(BASE + path);
        req.setMethod(method);
        req.setTimeout(TIMEOUT_MS);
        if (method == 'POST') {
            req.setHeader('Content-Type', 'application/x-www-form-urlencoded');
            req.setBody(encode(params));
        }
        if (idemKey != null) { req.setHeader('Idempotency-Key', idemKey); }

        StripeResponse r = new StripeResponse();
        try {
            HttpResponse res = new Http().send(req);
            r.status = res.getStatusCode();
            try {
                Object parsed = JSON.deserializeUntyped(res.getBody());
                if (parsed instanceof Map<String, Object>) { r.body = (Map<String, Object>) parsed; }
            } catch (Exception je) {
                System.debug(LoggingLevel.WARN, LOG + 'response was not JSON, status=' + r.status);
            }
            Object err = r.body.get('error');
            if (err instanceof Map<String, Object>) {
                Map<String, Object> em = (Map<String, Object>) err;
                r.errorType = (String) em.get('type');
                r.errorCode = (String) em.get('code');
            }
        } catch (CalloutException ce) {
            r.transportFailure = true;
            System.debug(LoggingLevel.ERROR, LOG + 'transport failure: ' + ce.getTypeName());
        }
        return r;
    }

    private static String encode(Map<String, String> params) {
        List<String> keys = new List<String>(params.keySet());
        keys.sort();
        List<String> parts = new List<String>();
        for (String k : keys) {
            parts.add(EncodingUtil.urlEncode(k, 'UTF-8') + '=' + EncodingUtil.urlEncode(params.get(k), 'UTF-8'));
        }
        return String.join(parts, '&');
    }
}
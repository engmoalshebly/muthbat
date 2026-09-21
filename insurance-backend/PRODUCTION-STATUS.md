# Production status

`insurance-backend` is intentionally isolated as a Demo/contract-test service.
It uses a mock insurance provider, mock payment mutations, and a local SQLite
database. It is not part of the Muthbat production deployment and its Docker
Compose service is available only under the `demo` profile.

The API still enforces authenticated-user ownership for every customer,
vehicle, quote, order, invoice, and policy lookup. This protects local and
staging demonstrations from cross-user IDOR, but does not make the service a
real insurance platform.

Before converting it to production, replace the mock provider and payment
endpoints, use a managed PostgreSQL database, implement real payment webhook
verification, add policy/document storage, and complete a regulatory/security
review.

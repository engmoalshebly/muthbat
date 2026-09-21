# Production release gate

Production is a separate Supabase project and must never reuse the staging
project, staging secrets, test OTPs, or direct-signup bypass.

## Provisioning

1. Create the project with `deploy/production/create-project.sh` using a secure
   database password held by the deployment operator.
2. Record only the project ref in CI; keep the database password in the secret
   manager.
3. Configure a dedicated OpenWA production host and WhatsApp session over HTTPS.
4. Run `deploy/production/deploy.sh` from a controlled runner.

## Required evidence before go-live

- Fresh migration application and `supabase db lint` pass in a production-like
  disposable project.
- pgTAP and Edge HTTP integration tests pass.
- Two real test accounts cannot read or mutate one another's tenant data.
- OTP expiry, replay, rate limiting, and OpenWA session recovery are verified.
- A backup is restored into a disposable project and the reconciliation checks
  pass.
- The mobile AAB is signed with the production upload key and has no debug
  signing configuration.

Production deployment is intentionally fail-closed when a required secret is
missing or when the environment is not explicitly `prod`.

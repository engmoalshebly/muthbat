# Central color system

- `lib/app/theme/app_colors.dart` defines Flutter colors and brand gradients.
- `lib/app/theme/app_theme.dart` applies the palette to Material components.
- `lib/app/theme/app_document_colors.dart` defines PDF export colors.
- `LocalPalette` and the entry screen theme reference `AppColors`.

Change palette tokens in `AppColors` to update their consumers across the app. Use semantic tokens such as `primary`, `error`, `paymentGreen`, and `textSecondary` in screens. Keep raw color declarations inside the central palette files. Apply opacity with `withValues(alpha: ...)` when needed.

Brand shades, illustration accents, messaging colors, and financial status colors have separate tokens in the same palette. Changing `primary` updates its consumers; it does not automatically regenerate related shades.

## Functional palette

| Token | Meaning | Hex |
| --- | --- | --- |
| `receivable` | Owed to the viewer | `#16845B` |
| `payable` | Owed by the viewer | `#D9534F` |
| `pending` | Pending transaction | `#E69A23` |
| `settled` | Settled, pair with a check mark | `#16845B` |
| `textPrimary` | Main text | `#1E293B` |
| `backgroundLight` | Page background | `#F8FAFC` |

`balanceColor` expects a balance from the viewer's perspective: positive is receivable, negative is payable. Customer-side server balances may use the merchant's perspective; invert the sign before using this helper. Movement type colors (`debtRed`, `paymentGreen`) are distinct from balance ownership.

The app brand now uses the functional green (`#16845B`) for primary controls and headers. Supporting surfaces use neutral slate or pale green; brand and splash gradients reference the same primary tokens. Legacy token names containing Blue remain compatibility aliases to the green palette.

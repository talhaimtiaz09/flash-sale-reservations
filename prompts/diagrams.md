# Diagram prompts

Four images for `docs/index.html`. Same style as the portfolio case studies
(`~/Desktop/portfolio/prompts/diagrams/style.md`).

1. New ChatGPT chat. Paste the **Style block**, wait for the confirmation.
2. Paste the **Context** block. ChatGPT replies "got it" and draws nothing.
3. Send each diagram prompt as its own message.
4. Save each image to its "Save as" path. Until a file exists, the page shows a dashed slot.

Check every label letter by letter. Watch `get_sale`, `Idempotency-Key`, `RETURN#` and `TransactionConflict`.
For a wrong label, reply: Keep everything exactly the same. Only change the label "X" to "Y".

## Style block (paste first)

```
You are a Diagram Architect AI. Every diagram in this chat follows this style exactly.

1. Canvas: landscape 3:2. Off-white background with a subtle light-grey graph-paper grid.
2. Strokes: hand-drawn, sketchy lines, slightly rough, like Excalidraw.
3. Shapes:
   - Dashed rounded boxes with light pastel fills group zones:
     pastel green = private / safe / the fix,
     pastel blue = cloud account, region, VPC or cluster,
     pastel purple = people, identity and CI,
     pastel yellow = end users and the product itself,
     pale grey = public internet, or the old / rejected approach.
   - Each service is a small flat 2D icon centred above its label. Use recognisable AWS / Google
     Cloud / Kubernetes / GitHub / GitLab / vendor-style icons where one exists. Generic things
     (person, phone, laptop, globe, database, key, file, shield) get simple flat icons.
4. Typography: a handwritten font (Virgil / Caveat style), dark charcoal. Short labels only.
5. Flow:
   - Dashed arrows show data/access flow.
   - Numbered orange circle badges (1, 2, 3...) mark the order of steps.
   - Small curved annotation arrows point to short inline notes (max 8 words each).
   - A blocked or rejected path is a dashed grey arrow that ends in a red ✕. A rejected box is
     grey and struck through.
   - The fix gets a small green check.
6. Layout: strict alignment, generous white space, nothing crammed.

TEXT RULES: use ONLY the labels I give, spelled exactly as written. No title, no legend, no
watermark, no extra text, no invented numbers, no company or client names.

Next I'll send a short project context, then one diagram per message. Don't generate anything
until I ask for a diagram. Confirm you understand.
```

## Context (paste second)

```
Project context. Don't draw anything yet, just read it and reply "got it".

A personal AWS lab: a reservation service for a fixed stock of units (tickets, a limited drop)
sold to far more buyers than there are units, all in the same few seconds. It has no real users.

- Buyers call an API Gateway HTTP API. The API throttles: past its limit it answers "429, try
  again" itself. Behind it are three Lambda functions: reserve (hold units for ten minutes),
  confirm (turn a hold into an order) and get_sale (read the stock that is left).
- Everything is stored in one DynamoDB table.
- The stock of a sale is not one number. It is split into several "shard" items. A buyer starts
  at a random shard and moves to another if that one is empty.
- A reservation is one DynamoDB transaction with three writes that all succeed or all fail:
  take units from a shard only if it has enough, write the hold, and write the buyer's
  Idempotency-Key only if it is new. A repeated key returns the same hold, never a second one.
- A hold is HELD until it is confirmed (it becomes an order) or it expires. Confirm refuses an
  expired hold.
- Expired holds give their units back by two paths. A sweeper function runs every minute from an
  EventBridge schedule and returns expired holds. DynamoDB TTL also deletes expired holds, late;
  the table's stream sends those deletes to a release function that returns the units.
- Both paths write a RETURN# marker in the same transaction as the stock return, so the same
  hold's units can only come back once.
- CloudWatch alarms send email through SNS.
```

## Diagram 1 · Hero
Save as `docs/images/flash-architecture.png`

```
Generate Diagram 1. Story: one API, five small functions and one table; two background paths put
unpaid stock back.

FAR LEFT (pastel yellow zone): a group of three person icons "Buyers".

CENTRE: big dashed pastel-blue box "AWS".
- Left inside it: API Gateway icon "HTTP API", small note "throttles: 429".
- Middle column, three Lambda icons stacked: "reserve", "confirm", "get_sale".
- Right: DynamoDB icon "Table", note "stock in shards".
- Below the table: a stream icon "Stream" → Lambda icon "release", note "TTL deletes".
- Above the table: EventBridge icon "Every minute" → Lambda icon "sweeper", note "expired holds".
- Bottom right corner: CloudWatch icon "Alarms" → SNS icon "Email".

ARROWS:
- Buyers → HTTP API: badge 1
- HTTP API → reserve, confirm, get_sale: badge 2
- reserve, confirm, get_sale → Table: badge 3
- Table → Stream → release → back to Table: thin dashed arrows, note "units back"
- sweeper → Table: thin dashed arrow, note "units back"

Keep the composition centred with empty graph paper around the edges.
```

## Diagram 2 · One reservation, one transaction
Save as `docs/images/flash-reserve-transaction.png`

```
Generate Diagram 2. Story: three writes that succeed or fail together, and what each failure
means.

LEFT: pastel yellow person icon "Buyer", label "reserve 1", small key icon "Idempotency-Key".
Arrow with badge 1 to a Lambda icon "reserve".

CENTRE: a big dashed pastel-green box "One transaction" containing three stacked boxes:
- "Shard: stock - 1", note "only if stock ≥ 1"
- "Write hold", note "HELD, 10 min"
- "Write key", note "only if new"

RIGHT: three outcome boxes, each with an arrow from the transaction box:
- badge 2, green check: "All three: new hold"
- grey box: "Shard empty", arrow curving back to reserve, note "try next shard"
- grey box: "Key exists", note "return the same hold"

No other text.
```

## Diagram 3 · Sharded stock
Save as `docs/images/flash-sharded-stock.png`

```
Generate Diagram 3. Story: one stock item becomes a bottleneck; the same stock in shards spreads
the writes.

TWO PANELS SIDE BY SIDE.

LEFT PANEL (pale grey, rejected), heading label "One stock item":
- many small person icons on the left, all arrows converging on one DynamoDB item box "stock"
- a red ✕ on the box, small labels "throttled" and "TransactionConflict"

RIGHT PANEL (pastel green, the fix), heading label "Stock in shards":
- the same person icons, arrows fanning out to five small item boxes "shard 0", "shard 1",
  "shard 2", "shard 3", "shard 4"
- one buyer's arrow, labelled "random shard", reaches "shard 2", which is greyed out with
  note "empty", and curves on to "shard 4", labelled "try the next"
- below the shards, a small sum sign and box "remaining = sum of shards", green check

Badges 1, 2 on the right panel only: 1 on "random shard", 2 on "try the next".
```

## Diagram 4 · Hold lifecycle
Save as `docs/images/flash-hold-lifecycle.png`

```
Generate Diagram 4. Story: every hold ends as an order or comes back to stock, and comes back
only once.

LEFT: box "HELD" with a small clock icon, note "10 minutes".

TOP PATH (pastel green): arrow from HELD, badge 1, label "confirm in time" → box "Order",
green check.

BOTTOM: arrow from HELD, label "expires" → a grey box "confirm refused" with a red ✕.
From HELD, two dashed paths go right to the same place:
- upper path: EventBridge icon "sweeper", note "every minute", badge 2
- lower path: DynamoDB TTL icon "TTL delete" → stream icon → Lambda icon "release",
  note "can be hours late", badge 3

Both paths end at one box "Stock + units", with a small tag icon "RETURN# marker" next to it and
a note "once, never twice".
```

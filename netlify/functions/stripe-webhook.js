const stripe = require('stripe')(process.env.STRIPE_SECRET_KEY);
const { createClient } = require('@supabase/supabase-js');

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY
);

// Map Stripe Price IDs to tiers
const PRICE_TIER_MAP = {
  [process.env.STRIPE_BASIC_PRICE_ID]: 'basic',
  [process.env.STRIPE_PREMIUM_PRICE_ID]: 'premium',
};

exports.handler = async (event) => {
  if (event.httpMethod !== 'POST') {
    return { statusCode: 405, body: 'Method Not Allowed' };
  }

  const sig = event.headers['stripe-signature'];
  let stripeEvent;

  try {
    stripeEvent = stripe.webhooks.constructEvent(
      event.body,
      sig,
      process.env.STRIPE_WEBHOOK_SECRET
    );
  } catch (err) {
    console.error('Webhook signature error:', err.message);
    return { statusCode: 400, body: 'Webhook Error: ' + err.message };
  }

  const obj = stripeEvent.data.object;

  try {
    if (stripeEvent.type === 'checkout.session.completed') {
      const session = obj;
      const customerId = session.customer;
      const subscriptionId = session.subscription;
      const clientEmail = session.customer_email || session.customer_details?.email;

      // Get the subscription details to find tier
      const subscription = await stripe.subscriptions.retrieve(subscriptionId);
      const priceId = subscription.items.data[0]?.price?.id;
      const tier = PRICE_TIER_MAP[priceId] || 'basic';
      const currentPeriodEnd = new Date(subscription.current_period_end * 1000).toISOString();

      // Find user by email
      const { data: users } = await supabase
        .from('user_profiles')
        .select('id')
        .eq('email', clientEmail)
        .limit(1);

      if (users && users.length > 0) {
        const userId = users[0].id;
        // Upsert subscription
        await supabase.from('subscriptions').upsert({
          user_id: userId,
          stripe_subscription_id: subscriptionId,
          stripe_customer_id: customerId,
          tier: tier,
          status: 'active',
          current_period_end: currentPeriodEnd,
          cancel_at_period_end: false,
          updated_at: new Date().toISOString()
        }, { onConflict: 'user_id' });
      }
    }

    if (stripeEvent.type === 'customer.subscription.updated') {
      const sub = obj;
      const status = sub.status === 'active' ? 'active' : sub.status;
      const priceId = sub.items.data[0]?.price?.id;
      const tier = PRICE_TIER_MAP[priceId] || 'basic';
      const currentPeriodEnd = new Date(sub.current_period_end * 1000).toISOString();

      await supabase.from('subscriptions')
        .update({
          status: status,
          tier: tier,
          current_period_end: currentPeriodEnd,
          cancel_at_period_end: sub.cancel_at_period_end,
          updated_at: new Date().toISOString()
        })
        .eq('stripe_subscription_id', sub.id);
    }

    if (stripeEvent.type === 'customer.subscription.deleted') {
      const sub = obj;
      await supabase.from('subscriptions')
        .update({ status: 'canceled', updated_at: new Date().toISOString() })
        .eq('stripe_subscription_id', sub.id);
    }

    if (stripeEvent.type === 'invoice.payment_failed') {
      const invoice = obj;
      await supabase.from('subscriptions')
        .update({ status: 'past_due', updated_at: new Date().toISOString() })
        .eq('stripe_customer_id', invoice.customer);
    }
  } catch (err) {
    console.error('Supabase update error:', err);
    return { statusCode: 500, body: 'Internal error' };
  }

  return { statusCode: 200, body: JSON.stringify({ received: true }) };
};

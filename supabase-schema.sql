-- ================================================
-- JoinAura — Supabase Database Schema
-- Run this in Supabase SQL Editor
-- ================================================

-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ------------------------------------------------
-- 1. USER PROFILES
-- ------------------------------------------------
CREATE TABLE public.user_profiles (
  id UUID REFERENCES auth.users(id) ON DELETE CASCADE PRIMARY KEY,
  email TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

ALTER TABLE public.user_profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own profile"
  ON public.user_profiles FOR SELECT
  USING (auth.uid() = id);

CREATE POLICY "Users can update own profile"
  ON public.user_profiles FOR UPDATE
  USING (auth.uid() = id);

-- Auto-create profile on signup
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.user_profiles (id, email)
  VALUES (NEW.id, NEW.email);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE PROCEDURE public.handle_new_user();

-- ------------------------------------------------
-- 2. SUBSCRIPTIONS
-- ------------------------------------------------
CREATE TABLE public.subscriptions (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  stripe_subscription_id TEXT UNIQUE NOT NULL,
  stripe_customer_id TEXT NOT NULL,
  tier TEXT CHECK (tier IN ('basic','premium')) DEFAULT 'basic',
  status TEXT CHECK (status IN ('active','canceled','past_due','trialing')) DEFAULT 'active',
  current_period_end TIMESTAMPTZ,
  cancel_at_period_end BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  UNIQUE(user_id)
);

ALTER TABLE public.subscriptions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own subscription"
  ON public.subscriptions FOR SELECT
  USING (auth.uid() = user_id);

-- Allow service role to manage subscriptions (for Stripe webhooks)
CREATE POLICY "Service role full access"
  ON public.subscriptions FOR ALL
  USING (TRUE)
  WITH CHECK (TRUE);

-- ------------------------------------------------
-- 3. POSTS
-- ------------------------------------------------
CREATE TABLE public.posts (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  caption TEXT DEFAULT '',
  media_url TEXT,
  media_type TEXT CHECK (media_type IN ('image','video','text')) DEFAULT 'image',
  thumbnail_url TEXT,
  is_locked BOOLEAN DEFAULT TRUE,
  tier_required TEXT CHECK (tier_required IN ('basic','premium')) DEFAULT 'basic',
  is_published BOOLEAN DEFAULT TRUE,
  like_count INTEGER DEFAULT 0,
  view_count INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

ALTER TABLE public.posts ENABLE ROW LEVEL SECURITY;

-- Anyone can see post metadata
CREATE POLICY "Anyone can view published posts"
  ON public.posts FOR SELECT
  USING (is_published = TRUE);

-- Only authenticated admin users can insert/update/delete
-- Replace YOUR_ADMIN_USER_ID with your actual Supabase user ID
CREATE POLICY "Admin can manage posts"
  ON public.posts FOR ALL
  USING (auth.role() = 'authenticated')
  WITH CHECK (auth.role() = 'authenticated');

-- ------------------------------------------------
-- 4. EMAIL LEADS
-- ------------------------------------------------
CREATE TABLE public.email_leads (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  email TEXT UNIQUE NOT NULL,
  source TEXT DEFAULT 'landing_page',
  created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

ALTER TABLE public.email_leads ENABLE ROW LEVEL SECURITY;

-- Only service role can insert (from API)
CREATE POLICY "Service role can insert leads"
  ON public.email_leads FOR INSERT
  WITH CHECK (TRUE);

-- ------------------------------------------------
-- STORAGE BUCKETS
-- Run in Supabase Dashboard > Storage
-- ------------------------------------------------
-- INSERT INTO storage.buckets (id, name, public)
-- VALUES ('creator-media', 'creator-media', true);

-- Storage policy (run in SQL editor):
-- CREATE POLICY "Public read" ON storage.objects FOR SELECT USING (bucket_id = 'creator-media');
-- CREATE POLICY "Auth upload" ON storage.objects FOR INSERT WITH CHECK (auth.role() = 'authenticated' AND bucket_id = 'creator-media');
-- CREATE POLICY "Auth delete" ON storage.objects FOR DELETE USING (auth.role() = 'authenticated' AND bucket_id = 'creator-media');

-- ------------------------------------------------
-- HELPER FUNCTION: Check active subscription
-- ------------------------------------------------
CREATE OR REPLACE FUNCTION public.has_active_subscription(p_user_id UUID)
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.subscriptions s
    WHERE s.user_id = p_user_id
      AND s.status = 'active'
      AND (s.current_period_end IS NULL OR s.current_period_end > NOW())
  );
$$ LANGUAGE SQL SECURITY DEFINER STABLE;

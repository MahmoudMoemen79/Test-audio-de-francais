-- French Audio Quiz — Supabase database
-- 1) Run this SQL in Supabase SQL Editor.
-- 2) Create your teacher account in Authentication > Users.
-- 3) Insert the teacher user id into profiles (see final INSERT below).

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role text not null default 'teacher' check (role in ('teacher')),
  created_at timestamptz not null default now()
);

create table if not exists public.tests (
  id uuid primary key default gen_random_uuid(),
  title text not null default 'Hörverstehen',
  instruction text not null default 'Hören Sie zuerst den folgenden Satz und wählen Sie dann die richtige Antwort aus.',
  play_limit integer not null default 1 check (play_limit >= 0 and play_limit <= 50),
  published boolean not null default true,
  updated_at timestamptz not null default now()
);

create table if not exists public.questions (
  id uuid primary key default gen_random_uuid(),
  test_id uuid not null references public.tests(id) on delete cascade,
  position integer not null,
  audio_url text not null,
  question_text text not null,
  options jsonb not null,
  correct_index integer not null check (correct_index between 0 and 3),
  correct_sentence text not null,
  active boolean not null default true,
  unique(test_id, position)
);

create table if not exists public.results (
  id uuid primary key default gen_random_uuid(),
  test_id uuid not null references public.tests(id) on delete cascade,
  student_name text not null,
  answers jsonb not null,
  score integer not null,
  total integer not null,
  percentage numeric(5,2) not null,
  created_at timestamptz not null default now()
);

insert into public.tests (id) values ('00000000-0000-0000-0000-000000000001')
on conflict (id) do nothing;

alter table public.profiles enable row level security;
alter table public.tests enable row level security;
alter table public.questions enable row level security;
alter table public.results enable row level security;

-- Teacher check
create or replace function public.is_teacher()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists(select 1 from public.profiles where id = auth.uid() and role = 'teacher');
$$;

-- Public test settings (only published test)
create or replace view public.published_tests as
select id, title, instruction, play_limit
from public.tests
where published = true;

-- Public question view: DOES NOT expose answer key.
create or replace view public.published_questions as
select id, test_id, position, audio_url, question_text, options
from public.questions
where active = true;

-- Secure grading: answer key stays server-side.
create or replace function public.grade_submission(p_test_id uuid, p_student_name text, p_answers jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  q record;
  item jsonb;
  idx integer;
  score integer := 0;
  total integer := 0;
  details jsonb := '[]'::jsonb;
  chosen integer;
  is_correct boolean;
begin
  if length(trim(coalesce(p_student_name,''))) < 1 then
    raise exception 'Student name is required';
  end if;

  for q in
    select id, position, question_text, options, correct_index, correct_sentence
    from public.questions
    where test_id = p_test_id and active = true
    order by position
  loop
    total := total + 1;
    item := coalesce(p_answers -> q.id::text, 'null'::jsonb);
    if jsonb_typeof(item) = 'number' then
      chosen := (item #>> '{}')::integer;
    else
      chosen := null;
    end if;
    is_correct := chosen is not null and chosen = q.correct_index;
    if is_correct then score := score + 1; end if;

    details := details || jsonb_build_array(jsonb_build_object(
      'question_id', q.id,
      'position', q.position,
      'question', q.question_text,
      'selected_index', chosen,
      'selected_text', case when chosen between 0 and 3 then q.options->>chosen::text else null end,
      'correct_index', q.correct_index,
      'correct_text', q.options->>q.correct_index::text,
      'correct_sentence', q.correct_sentence,
      'correct', is_correct
    ));
  end loop;

  insert into public.results(test_id, student_name, answers, score, total, percentage)
  values (p_test_id, trim(p_student_name), p_answers, score, total,
          case when total = 0 then 0 else round(score::numeric * 100 / total, 2) end);

  return jsonb_build_object(
    'score', score,
    'total', total,
    'percentage', case when total = 0 then 0 else round(score::numeric * 100 / total, 2) end,
    'details', details
  );
end;
$$;

-- RLS policies
drop policy if exists "teacher profiles" on public.profiles;
create policy "teacher profiles" on public.profiles
for select to authenticated using (id = auth.uid() and role='teacher');

drop policy if exists "published tests public" on public.tests;
create policy "published tests public" on public.tests
for select to anon, authenticated using (published = true or public.is_teacher());

drop policy if exists "teacher tests write" on public.tests;
create policy "teacher tests write" on public.tests
for all to authenticated using (public.is_teacher()) with check (public.is_teacher());

drop policy if exists "teacher questions" on public.questions;
create policy "teacher questions" on public.questions
for all to authenticated using (public.is_teacher()) with check (public.is_teacher());

drop policy if exists "teacher results" on public.results;
create policy "teacher results" on public.results
for select to authenticated using (public.is_teacher());

-- The views expose only safe fields to the student side.
grant select on public.published_tests to anon, authenticated;
grant select on public.published_questions to anon, authenticated;
grant execute on function public.grade_submission(uuid,text,jsonb) to anon, authenticated;

-- After creating your teacher user, run:
-- insert into public.profiles(id, role) values ('YOUR-AUTH-USER-UUID', 'teacher')
-- on conflict (id) do update set role='teacher';

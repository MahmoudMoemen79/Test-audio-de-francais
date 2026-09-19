-- Autoriser l'enseignant à supprimer les participations / résultats
DROP POLICY IF EXISTS "teacher delete results" ON public.results;
CREATE POLICY "teacher delete results"
ON public.results
FOR DELETE
TO authenticated
USING (public.is_teacher());

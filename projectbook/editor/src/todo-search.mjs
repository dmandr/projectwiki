const normalize=value=>value.normalize('NFKC').toLocaleLowerCase();
export function matchesTodoQuery(title,query) {
  const text=normalize(title);
  return normalize(query).trim().split(/\s+/).filter(Boolean).every(term=>text.includes(term));
}
export function filterTodoTasks(tasks,query,listIds) {
  const selected=new Set(listIds);
  return tasks.filter(task=>selected.has(task.list_id) && matchesTodoQuery(task.title,query));
}

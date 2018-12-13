program HelloWorld
  CHARACTER target*100
  call getenv('TARGET', target)
  if (target == "") then
    target = "world"
  endif
  write (*,*) "Hello, ", trim(target), "!"
end program HelloWorld

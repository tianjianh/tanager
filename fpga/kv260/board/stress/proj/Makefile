OBJS = main.o f0.o f1.o f2.o f3.o f4.o f5.o f6.o f7.o
p: $(OBJS)
	$(CC) -O2 -o $@ $(OBJS)
%.o: %.c
	$(CC) -O2 -c -o $@ $<
clean:
	rm -f p $(OBJS)

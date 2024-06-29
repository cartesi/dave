CCFLAGS=-O2

playpal2rgb: playpal2rgb.o
	$(CC) $^ -o $@ $(CCFLAGS)

%.o: %.c
	$(CC) -c $< -o $@ $(CCFLAGS)

.PHONY: clean
clean:
	rm -vf *.o playpal2rgb

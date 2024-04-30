playpal2rgb: playpal.o playpal2rgb.o
	$(CC) $^ -o $@

%.o: %.c
	$(CC) -c $< -o $@

.PHONY: clean
clean:
	rm -f *.o playpal2rgb

FROM cartesi/machine-emulator:0.18.1
USER root 

COPY ./bins ./bins
COPY ./gen_machine_simple.sh .
RUN chmod +x gen_machine_simple.sh
RUN ./gen_machine_simple.sh && tar -zvcf /simple-program.tar.gz simple-program
